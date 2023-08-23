class Tag < ApplicationRecord
  COUNT_METATAGS = %w[
    comment_count
  ]

  BOOLEAN_METATAGS = %w[
    hassource hasdescription isparent ischild inpool pending_replacements
  ].freeze

  NEGATABLE_METATAGS = %w[
    id filetype type rating description parent user user_id approver flagger deletedby delreason
    source status pool set fav favoritedby note locked upvote votedup downvote voteddown voted
    width height mpixels ratio filesize duration score favcount date age change tagcount
    commenter comm noter noteupdater
  ] + TagCategory::SHORT_NAME_LIST.map { |tag_name| "#{tag_name}tags" }

  METATAGS = %w[
    md5 order limit child randseed ratinglocked notelocked statuslocked
  ] + NEGATABLE_METATAGS + COUNT_METATAGS + BOOLEAN_METATAGS

  ORDER_METATAGS = %w[
    id id_desc
    score score_asc
    favcount favcount_asc
    created_at created_at_asc
    updated updated_desc updated_asc
    comment comment_asc
    comment_bumped comment_bumped_asc
    note note_asc
    mpixels mpixels_asc
    portrait landscape
    filesize filesize_asc
    tagcount tagcount_asc
    change change_desc change_asc
    duration duration_desc duration_asc
    rank
    random
  ] +
      COUNT_METATAGS +
      TagCategory::SHORT_NAME_LIST.flat_map { |str| ["#{str}tags", "#{str}tags_asc"] }

  has_one :wiki_page, :foreign_key => "title", :primary_key => "name"
  has_one :artist, :foreign_key => "name", :primary_key => "name"
  has_one :antecedent_alias, -> {active}, :class_name => "TagAlias", :foreign_key => "antecedent_name", :primary_key => "name"
  has_many :consequent_aliases, -> {active}, :class_name => "TagAlias", :foreign_key => "consequent_name", :primary_key => "name"
  has_many :antecedent_implications, -> {active}, :class_name => "TagImplication", :foreign_key => "antecedent_name", :primary_key => "name"
  has_many :consequent_implications, -> {active}, :class_name => "TagImplication", :foreign_key => "consequent_name", :primary_key => "name"

  validates :name, uniqueness: true, tag_name: true, on: :create
  validates :name, length: { in: 1..100 }
  validates :category, inclusion: { in: TagCategory::CATEGORY_IDS }
  validate :user_can_create_tag?, on: :create
  validate :user_can_change_category?, if: :category_changed?

  before_save :update_category, if: :category_changed?

  class CategoryMapping
    TagCategory::REVERSE_MAPPING.each do |value, category|
      define_method(category) do
        value
      end
    end

    def regexp
      @regexp ||= Regexp.compile(TagCategory::MAPPING.keys.sort_by { |x| -x.length }.join("|"))
    end

    def value_for(string)
      TagCategory::MAPPING[string.to_s.downcase] || 0
    end
  end

  module CountMethods
    extend ActiveSupport::Concern

    module ClassMethods
      def increment_post_counts(tag_names)
        return if tag_names.empty?

        Tag.where(name: tag_names).order(:name).lock("FOR UPDATE").pluck(1)
        Tag.where(name: tag_names).update_all("post_count = post_count + 1")
      end

      def decrement_post_counts(tag_names)
        return if tag_names.empty?

        Tag.where(name: tag_names).order(:name).lock("FOR UPDATE").pluck(1)
        Tag.where(name: tag_names).update_all("post_count = post_count - 1")
      end

      def clean_up_negative_post_counts!
        Tag.where("post_count < 0").find_each do |tag|
          tag_alias = TagAlias.where("status in ('active', 'processing') and antecedent_name = ?", tag.name).first
          tag.fix_post_count
          if tag_alias
            tag_alias.consequent_tag.fix_post_count
          end
        end
      end
    end

    def real_post_count
      @real_post_count ||= Post.raw_tag_match(name).count_only
    end

    def fix_post_count
      update_column(:post_count, real_post_count)
    end
  end

  module CategoryMethods
    module ClassMethods
      def categories
        @category_mapping ||= CategoryMapping.new
      end

      def category_for(tag_name)
        Cache.fetch("tc:#{tag_name}") do
          Tag.where(name: tag_name).pick(:category).to_i
        end
      end

      def categories_for(tag_names, disable_cache: false)
        if disable_cache
          tag_cats = {}
          Tag.where(name: Array(tag_names)).select([:id, :name, :category]).find_each do |tag|
            tag_cats[tag.name] = tag.category
          end
          tag_cats
        else
          found = Cache.read_multi(Array(tag_names), "tc")
          not_found = tag_names - found.keys
          if not_found.count > 0
            # Is multi_write worth it here? Normal usage of this will be short put lists and then never touched.
            Tag.where(name: not_found).select([:id, :name, :category]).find_each do |tag|
              Cache.write("tc:#{tag.name}", tag.category)
              found[tag.name] = tag.category
            end
          end
          found
        end
      end

      def category_for_value(value)
        TagCategory::REVERSE_MAPPING.fetch(value, "unknown category").capitalize
      end
    end

    def self.included(m)
      m.extend(ClassMethods)
    end

    def category_name
      TagCategory::REVERSE_MAPPING[category].capitalize
    end

    def update_category_post_counts!
      Post.with_timeout(30_000, nil, {:tags => name}) do
        Post.sql_raw_tag_match(name).find_each do |post|
          post.set_tag_counts(disable_cache: false)
          args = TagCategory::CATEGORIES.to_h { |x| ["tag_count_#{x}", post.send("tag_count_#{x}")] }.update("tag_count" => post.tag_count)
          Post.where(:id => post.id).update_all(args)
          post.update_index
        end
      end
    end

    def update_category_post_counts
      UpdateTagCategoryJob.perform_later(id)
    end

    def update_category_cache
      Cache.write("tc:#{name}", category, expires_in: 3.hours)
    end

    def user_can_change_category?
      cat = TagCategory::REVERSE_MAPPING[category]
      if !CurrentUser.is_admin? && TagCategory::ADMIN_ONLY_MAPPING[cat]
        errors.add(:category,  "can only used by admins")
        return false
      end
      if cat == "lore"
        unless name =~ /\A.*_\(lore\)\z/
          errors.add(:category, "can only be applied to tags that end with '_(lore)'")
          return false
        end
      end
    end

    def update_category
      update_category_cache
      write_category_change_entry unless new_record?
      update_category_post_counts unless new_record?
    end

    def write_category_change_entry
      TagTypeVersion.create(creator_id: CurrentUser.id,
                            tag_id: id,
                            old_type: category_was.to_i,
                            new_type: category.to_i,
                            is_locked: is_locked?)
    end
  end

  module NameMethods
    def normalize_name(name)
      name.to_s.unicode_normalize(:nfc).downcase.strip.tr(" ", "_").to_s
    end

    def find_by_normalized_name(name)
      find_by_name(normalize_name(name))
    end

    def find_by_name_list(names)
      names = names.map {|x| [normalize_name(x), nil]}.to_h
      existing = Tag.where(name: names.keys).to_a
      existing.each do |x|
        names[x.name] = x
      end
      names
    end

    def find_or_create_by_name_list(names, creator: CurrentUser.user)
      names = names.map {|x| normalize_name(x)}
      names = names.map do |x|
        if x =~ /\A(#{categories.regexp}):(.+)\Z/
          [$2, $1]
        else
          [x, nil]
        end
      end.to_h

      existing = Tag.where(name: names.keys).to_a
      existing.each do |tag|
        cat = names[tag.name]
        category_id = categories.value_for(cat)
        if cat && category_id != tag.category
          if tag.category_editable_by_implicit?(creator)
            tag.update(category: category_id)
          else
            tag.errors.add(:category, "cannot be changed implicitly through a tag prefix")
          end
        end
        names.delete(tag.name)
      end

      names.each do |name, cat|
        existing << Tag.new.tap do |t|
          t.name = name
          t.category = categories.value_for(cat)
          t.save
        end
      end
      existing
    end

    def find_or_create_by_name(name, creator: CurrentUser.user)
      name = normalize_name(name)
      category = nil

      if name =~ /\A(#{categories.regexp}):(.+)\Z/
        category = $1
        name = $2
      end

      tag = find_by_name(name)

      if tag
        if category
          category_id = categories.value_for(category)
            # in case a category change hasn't propagated to this server yet,
            # force an update the local cache. This may get overwritten in the
            # next few lines if the category is changed.
            tag.update_category_cache

          unless category_id == tag.category
            if tag.category_editable_by_implicit?(creator)
              tag.update(category: category_id)
            else
              tag.errors.add(:category, "cannot be changed implicitly through a tag prefix")
            end
          end
        end

        tag
      else
        Tag.new.tap do |t|
          t.name = name
          t.category = categories.value_for(category)
          t.save
        end
      end
    end
  end

  module ParseMethods
    def normalize(query)
      query.to_s.unicode_normalize(:nfc).strip
    end

    def normalize_query(query)
      tags = Tag.scan_tags(query.to_s)
      tags = tags.map {|t| Tag.normalize_name(t)}
      tags = TagAlias.to_aliased(tags)
      tags.sort.uniq.join(" ")
    end

    def scan_tags(tags)
      tagstr = normalize(tags)
      list = tagstr.scan(/-?source:".*?"/) || []
      list + tagstr.gsub(/-?source:".*?"/, "").scan(/[^[:space:]]+/).uniq
    end

    def pull_wildcard_tags(tag)
      matches = Tag.name_matches(tag).limit(Danbooru.config.tag_query_limit).order("post_count DESC").pluck(:name)
      matches = ['~~not_found~~'] if matches.empty?
      matches
    end

    def parse_boolean(value)
      value&.downcase == 'true'
    end

    def parse_tag(tag, output)
      tag = tag.downcase
      if tag.start_with?("-") && tag.length > 1
        if tag.include?("*")
          output[:exclude] += pull_wildcard_tags(tag.delete_prefix("-"))
        else
          output[:exclude] << tag.delete_prefix("-")
        end

      elsif tag[0] == "~" && tag.length > 1
        output[:include] << tag.delete_prefix("~")

      elsif tag.include?("*")
        output[:include] += pull_wildcard_tags(tag)

      else
        output[:related] << tag.downcase
      end
    end

    def has_metatag?(tags, *)
      fetch_metatag(tags, *).present?
    end

    def fetch_metatag(tags, *metatags)
      return nil if tags.blank?

      tags = scan_tags(tags) if tags.is_a?(String)
      tags.find do |tag|
        metatag_name, value = tag.split(":", 2)
        return value if metatags.include?(metatag_name)
      end
    end

    def add_to_query(q, type, key, any_none_key: nil, value: nil, wildcard: false, &) # rubocop:disable Metrics/ParameterLists (TODO: convert to class)
      if any_none_key && (value.downcase == "none" || value.downcase == "any")
        add_any_none_to_query(q, type, value.downcase, any_none_key)
        return
      end

      value = yield
      value = value.squeeze("*") if wildcard # Collapse runs of wildcards for efficiency

      case type
      when :must
        q[key] ||= []
        q[key] << value
      when :must_not
        q[:"#{key}_neg"] ||= []
        q[:"#{key}_neg"] << value
      end
    end

    def add_any_none_to_query(q, type, value, key)
      case type
      when :must
        q[key] = value
      when :must_not
        if value == "none"
          q[key] = "any"
        else
          q[key] = "none"
        end
      end
    end

    def add_to_query_single(q, type, key)
      case type
      when :must
        q[key] = yield
      when :must_not
        q[:"#{key}_neg"] = yield
      end
    end

    def parse_query(query, options = {})
      q = {
        tag_count: 0,
        tags: {
          related: [],
          include: [],
          exclude: [],
        },
      }

      def id_or_invalid(val)
        return -1 if val.blank?
        val
      end

      scan_tags(query).each do |token|
        q[:tag_count] += 1 unless Danbooru.config.is_unlimited_tag?(token)
        metatag_name, g2 = token.split(":", 2)

        # Short-circuit when there is no metatag or the metatag has no value
        if g2.blank?
          parse_tag(token, q[:tags])
          next
        end

        type = metatag_name.start_with?("-") ? :must_not : :must
        case metatag_name.downcase
        when "user", "-user"
          add_to_query(q, type, :uploader_ids) do
            user_id = User.name_or_id_to_id(g2)
            id_or_invalid(user_id)
          end

        when "user_id", "-user_id"
          add_to_query(q, type, :uploader_ids) do
            g2.to_id
          end

        when "approver", "-approver"
          add_to_query(q, type, :approver_ids, any_none_key: :approver, value: g2) do
            user_id = User.name_or_id_to_id(g2)
            id_or_invalid(user_id)
          end

        when "commenter", "-commenter", "comm", "-comm"
          add_to_query(q, type, :commenter_ids, any_none_key: :commenter, value: g2) do
            user_id = User.name_or_id_to_id(g2)
            id_or_invalid(user_id)
          end

        when "noter", "-noter"
          add_to_query(q, type, :noter_ids, any_none_key: :noter, value: g2) do
            user_id = User.name_or_id_to_id(g2)
            id_or_invalid(user_id)
          end

        when "noteupdater", "-noteupdater"
          add_to_query(q, type, :note_updater_ids) do
            user_id = User.name_or_id_to_id(g2)
            id_or_invalid(user_id)
          end

        when "pool", "-pool"
          add_to_query(q, type, :pool_ids, any_none_key: :pool, value: g2) do
            Pool.name_to_id(g2)
          end

        when "set", "-set"
          add_to_query(q, type, :set_ids) do
            post_set_id = PostSet.name_to_id(g2)
            post_set = PostSet.find_by(id: post_set_id)

            next 0 unless post_set
            unless post_set.can_view?(CurrentUser.user)
              raise User::PrivilegeError
            end

            post_set_id
          end

        when "fav", "favoritedby", "-fav", "-favoritedby"
          add_to_query(q, type, :fav_ids) do
            favuser = User.find_by_name_or_id(g2)

            next 0 unless favuser
            if favuser.hide_favorites?
              raise Favorite::HiddenError
            end

            favuser.id
          end

        when "md5"
          q[:md5] = g2.downcase.split(",")[0..99]

        when "rating", "-rating"
          add_to_query(q, type, :rating) { g2[0]&.downcase || "miss" }

        when "locked", "-locked"
          add_to_query(q, type, :locked) do
            case g2.downcase
            when "rating"
              :rating
            when "note", "notes"
              :note
            when "status"
              :status
            end
          end

        when "ratinglocked"
          add_to_query(q, parse_boolean(g2) ? :must : :must_not, :locked) { :rating }
        when "notelocked"
          add_to_query(q, parse_boolean(g2) ? :must : :must_not, :locked) { :note }
        when "statuslocked"
          add_to_query(q, parse_boolean(g2) ? :must : :must_not, :locked) { :status }

        when "id"
          q[:post_id] = ParseValue.range(g2)

        when "-id"
          q[:post_id_neg] = g2.to_i

        when "width", "-width"
          add_to_query(q, type, :width) { ParseValue.range(g2) }

        when "height", "-height"
          add_to_query(q, type, :height) { ParseValue.range(g2) }

        when "mpixels", "-mpixels"
          add_to_query(q, type, :mpixels) { ParseValue.range_fudged(g2, :float) }

        when "ratio", "-ratio"
          add_to_query(q, type, :ratio) { ParseValue.range(g2, :ratio) }

        when "duration", "-duration"
          add_to_query(q, type, :duration) { ParseValue.range(g2, :float) }

        when "score", "-score"
          add_to_query(q, type, :score) { ParseValue.range(g2) }

        when "favcount", "-favcount"
          add_to_query(q, type, :fav_count) { ParseValue.range(g2) }

        when "filesize", "-filesize"
          add_to_query(q, type, :filesize) { ParseValue.range_fudged(g2, :filesize) }

        when "change", "-change"
          add_to_query(q, type, :change_seq) { ParseValue.range(g2) }

        when "source", "-source"
          add_to_query(q, type, :sources, any_none_key: :source, value: g2, wildcard: true) do
            src = g2.gsub(/\A"(.*)"\Z/, '\1')
            "#{src}*"
          end

        when "date", "-date"
          add_to_query(q, type, :date) { ParseValue.date_range(g2) }

        when "age", "-age"
          add_to_query(q, type, :age) { ParseValue.invert_range(ParseValue.range(g2, :age)) }

        when "tagcount", "-tagcount"
          add_to_query(q, type, :post_tag_count) { ParseValue.range(g2) }

        when /-?(#{TagCategory::SHORT_NAME_REGEX})tags/
          add_to_query(q, type, :"#{TagCategory::SHORT_NAME_MAPPING[$1]}_tag_count") { ParseValue.range(g2) }

        when "parent", "-parent"
          add_to_query(q, type, :parent_ids, any_none_key: :parent, value: g2) do
            g2.to_i
          end

        when "child"
          q[:child] = g2.downcase

        when "randseed"
          q[:random] = g2.to_i

        when "order"
          g2 = g2.downcase

          order, suffix, _ = g2.partition(/_(asc|desc)\z/i)

          q[:order] = g2

        when "limit"
          # Do nothing. The controller takes care of it.

        when "status", "-status"
          add_to_query_single(q, type, :status) { g2.downcase }

        when "filetype", "type", "-filetype", "-type"
          add_to_query(q, type, :filetype) { g2.downcase }

        when "description", "-description"
          add_to_query(q, type, :description) { g2 }

        when "note", "-note"
          add_to_query(q, type, :note) { g2 }

        when "delreason", "-delreason"
          q[:status] ||= "any"
          add_to_query(q, type, :delreason, wildcard: true) { g2 }

        when "deletedby", "-deletedby"
          q[:status] ||= "any"
          add_to_query(q, type, :deleter) do
            user_id = User.name_or_id_to_id(g2)
            id_or_invalid(user_id)
          end

        when "upvote", "votedup", "-upvote", "-votedup"
          add_to_query(q, type, :upvote) do
            if CurrentUser.is_moderator?
              user_id = User.name_or_id_to_id(g2)
            elsif CurrentUser.is_member?
              user_id = CurrentUser.id
            end
            id_or_invalid(user_id)
          end

        when "downvote", "voteddown", "-downvote", "-voteddown"
          add_to_query(q, type, :downvote) do
            if CurrentUser.is_moderator?
              user_id = User.name_or_id_to_id(g2)
            elsif CurrentUser.is_member?
              user_id = CurrentUser.id
            end
            id_or_invalid(user_id)
          end

        when "voted", "-voted"
          add_to_query(q, type, :voted) do
            if CurrentUser.is_moderator?
              user_id = User.name_or_id_to_id(g2)
            elsif CurrentUser.is_member?
              user_id = CurrentUser.id
            end
            id_or_invalid(user_id)
          end

        when *COUNT_METATAGS
          q[metatag_name.downcase.to_sym] = ParseValue.range(g2)

        when *BOOLEAN_METATAGS
          q[metatag_name.downcase.to_sym] = parse_boolean(g2)

        else
          parse_tag(token, q[:tags])
        end
      end

      normalize_tags_in_query(q)

      return q
    end

    def normalize_tags_in_query(query_hash)
      query_hash[:tags][:exclude] = TagAlias.to_aliased(query_hash[:tags][:exclude])
      query_hash[:tags][:include] = TagAlias.to_aliased(query_hash[:tags][:include])
      query_hash[:tags][:related] = TagAlias.to_aliased(query_hash[:tags][:related])
    end
  end

  module RelationMethods
    def update_related
      return unless should_update_related?

      self.related_tags = RelatedTagCalculator.calculate_from_sample_to_array(name).join(" ")
      self.related_tags_updated_at = Time.now
      fix_post_count if post_count > 20 && rand(post_count) <= 1
      save
    rescue ActiveRecord::StatementInvalid
    end

    def update_related_if_outdated
      if Cache.fetch("urt:#{name}").nil? && should_update_related?
        TagUpdateRelatedJob.perform_later(id)
        Cache.write("urt:#{name}", true, expires_in: 10.minutes) # mutex to prevent redundant updates
      end
    end

    def related_cache_expiry
      base = Math.sqrt([post_count, 0].max)
      if base > 24 * 30
        24 * 30
      elsif base < 24
        24
      else
        base
      end
    end

    def should_update_related?
      related_tags.blank? || related_tags_updated_at.blank? || related_tags_updated_at < related_cache_expiry.hours.ago
    end

    def related_tag_array
      update_related_if_outdated
      related_tags.to_s.split(/ /).in_groups_of(2)
    end
  end

  module SearchMethods
    def empty
      where("tags.post_count <= 0")
    end

    def nonempty
      where("tags.post_count > 0")
    end

    # ref: https://www.postgresql.org/docs/current/static/pgtrgm.html#idm46428634524336
    def order_similarity(name)
      # trunc(3 * sim) reduces the similarity score from a range of 0.0 -> 1.0 to just 0, 1, or 2.
      # This groups tags first by approximate similarity, then by largest tags within groups of similar tags.
      order(Arel.sql("trunc(3 * similarity(name, #{connection.quote(name)})) DESC"), "post_count DESC", "name DESC")
    end

    # ref: https://www.postgresql.org/docs/current/static/pgtrgm.html#idm46428634524336
    def fuzzy_name_matches(name)
      where("tags.name % ?", name)
    end

    def name_matches(name)
      where("tags.name LIKE ? ESCAPE E'\\\\'", normalize_name(name).to_escaped_for_sql_like)
    end

    def search(params)
      q = super

      if params[:fuzzy_name_matches].present?
        q = q.fuzzy_name_matches(params[:fuzzy_name_matches])
      end

      if params[:name_matches].present?
        q = q.name_matches(params[:name_matches])
      end

      if params[:name].present?
        q = q.where("tags.name": normalize_name(params[:name]).split(","))
      end

      if params[:category].present?
        category_ids = params[:category].split(",").first(100).grep(/^\d+$/)
        q = q.where(category: category_ids)
      end

      if params[:hide_empty].blank? || params[:hide_empty].to_s.truthy?
        q = q.where("post_count > 0")
      end

      if params[:has_wiki].to_s.truthy?
        q = q.joins(:wiki_page).where("wiki_pages.is_deleted = false")
      elsif params[:has_wiki].to_s.falsy?
        q = q.joins("LEFT JOIN wiki_pages ON tags.name = wiki_pages.title").where("wiki_pages.title IS NULL OR wiki_pages.is_deleted = true")
      end

      if params[:has_artist].to_s.truthy?
        q = q.joins("INNER JOIN artists ON tags.name = artists.name")
      elsif params[:has_artist].to_s.falsy?
        q = q.joins("LEFT JOIN artists ON tags.name = artists.name").where("artists.name IS NULL")
      end

      q = q.attribute_matches(:is_locked, params[:is_locked])

      case params[:order]
      when "name"
        q = q.order("name")
      when "date"
        q = q.order("id desc")
      when "count"
        q = q.order("post_count desc")
      when "similarity"
        q = q.order_similarity(params[:fuzzy_name_matches]) if params[:fuzzy_name_matches].present?
      else
        q = q.apply_basic_order(params)
      end

      q
    end
  end

  def category_editable_by_implicit?(user)
    return false unless user.is_janitor?
    return false if is_locked?
    return false if post_count >= Danbooru.config.tag_type_change_cutoff
    true
  end

  def category_editable_by?(user)
    return true if user.is_admin?
    return false if is_locked?
    return false if TagCategory::ADMIN_ONLY_MAPPING[TagCategory::REVERSE_MAPPING[category]]
    return true if post_count < Danbooru.config.tag_type_change_cutoff
    false
  end

  def user_can_create_tag?
    if name =~ /\A.*_\(lore\)\z/ && !CurrentUser.user.is_admin?
      errors.add(:base, "Can not create lore tags unless admin")
      errors.add(:name, "is invalid")
      return false
    end
    true
  end

  include CountMethods
  include CategoryMethods
  extend NameMethods
  extend ParseMethods
  include RelationMethods
  extend SearchMethods
end
