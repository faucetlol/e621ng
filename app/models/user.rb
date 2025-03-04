class User < ApplicationRecord
  class Error < Exception ; end
  class PrivilegeError < Exception
    attr_accessor :message

    def initialize(msg = nil)
      @message = "Access Denied: #{msg}" if msg
    end
  end

  module Levels
    Danbooru.config.levels.each do |name, level|
      const_set(name.upcase.tr(' ', '_'), level)
    end
  end

  # Used for `before_action :<role>_only`. Must have a corresponding `is_<role>?` method.
  Roles = Levels.constants.map(&:downcase) + [
    :banned,
    :approver,
    :voter,
    :verified,
  ]

  # candidates for removal:
  # - disable_cropped_thumbnails (enabled by 22)
  # - has_saved_searches (removed in removal of saved searches)
  # - no_feedback
  # - show_avatars
  # - blacklist_avatars
  # - disable_mobile_gestures
  # - disable_post_tooltips
  BOOLEAN_ATTRIBUTES = %w(
    show_avatars
    blacklist_avatars
    blacklist_users
    description_collapsed_initially
    hide_comments
    show_hidden_comments
    show_post_statistics
    is_banned
    has_mail
    receive_email_notifications
    enable_keyboard_navigation
    enable_privacy_mode
    style_usernames
    enable_auto_complete
    has_saved_searches
    can_approve_posts
    can_upload_free
    disable_cropped_thumbnails
    disable_mobile_gestures
    enable_safe_mode
    disable_responsive_mode
    disable_post_tooltips
    no_flagging
    no_feedback
    disable_user_dmails
    enable_compact_uploader
    replacements_beta
  )

  include Danbooru::HasBitFlags
  has_bit_flags BOOLEAN_ATTRIBUTES, :field => "bit_prefs"

  attr_accessor :password, :old_password, :validate_email_format, :skip_email_blank_check

  after_initialize :initialize_attributes, if: :new_record?

  validates :email, presence: { if: :enable_email_verification? }
  validates :email, uniqueness: { case_sensitive: false, if: :enable_email_verification? }
  validates :email, format: { with: /\A.+@[^ ,;@]+\.[^ ,;@]+\z/, if: :enable_email_verification? }
  validate :validate_email_address_allowed, on: [:create, :update], if: ->(rec) { (rec.new_record? && rec.email.present?) || (rec.email.present? && rec.email_changed?) }

  validates :name, user_name: true, on: :create
  validates :default_image_size, inclusion: { :in => %w(large fit fitv original) }
  validates :per_page, inclusion: { :in => 1..320 }
  validates :comment_threshold, presence: true
  validates :comment_threshold, numericality: { only_integer: true, less_than: 50_000, greater_than: -50_000 }
  validates :password, length: { :minimum => 6, :if => ->(rec) { rec.new_record? || rec.password.present? || rec.old_password.present? } }
  validates :password, confirmation: true
  validates :password_confirmation, presence: { if: ->(rec) { rec.new_record? || rec.old_password.present? } }
  validate :validate_ip_addr_is_not_banned, :on => :create
  validate :validate_sock_puppets, :on => :create, :if => -> { Danbooru.config.enable_sock_puppet_validation? }
  before_validation :normalize_blacklisted_tags, if: ->(rec) { rec.blacklisted_tags_changed? }
  before_validation :set_per_page
  before_validation :staff_cant_disable_dmail
  before_validation :blank_out_nonexistent_avatars
  validates :blacklisted_tags, length: { maximum: 150_000 }
  validates :custom_style, length: { maximum: 500_000 }
  validates :profile_about, length: { maximum: Danbooru.config.user_about_max_size }
  validates :profile_artinfo, length: { maximum: Danbooru.config.user_about_max_size }
  validates :time_zone, inclusion: { in: ActiveSupport::TimeZone.all.map(&:name) }
  before_create :encrypt_password_on_create
  before_update :encrypt_password_on_update
  after_save :update_cache
  #after_create :notify_sock_puppets
  after_create :create_user_status
  has_many :feedback, :class_name => "UserFeedback", :dependent => :destroy
  has_many :posts, :foreign_key => "uploader_id"
  has_many :post_approvals, :dependent => :destroy
  has_many :post_disapprovals, :dependent => :destroy
  has_many :post_votes
  has_many :post_versions
  has_many :note_versions
  has_many :bans, -> { order("bans.id desc") }
  has_many :staff_notes, -> { order("staff_notes.id desc") }
  has_one :recent_ban, -> { order("bans.id desc") }, class_name: "Ban"
  has_one :user_status

  has_one :api_key
  has_one :dmail_filter
  has_many :forum_topic_visits
  has_many :note_versions, :foreign_key => "updater_id"
  has_many :dmails, -> {order("dmails.id desc")}, :foreign_key => "owner_id"
  has_many :forum_posts, -> {order("forum_posts.created_at, forum_posts.id")}, :foreign_key => "creator_id"
  has_many :user_name_change_requests, -> { order(id: :asc) }
  has_many :post_sets, -> {order(name: :asc)}, foreign_key: :creator_id
  has_many :favorites, -> {order(id: :desc)}
  belongs_to :avatar, class_name: 'Post', optional: true
  accepts_nested_attributes_for :dmail_filter

  module BanMethods
    def validate_ip_addr_is_not_banned
      if IpBan.is_banned?(CurrentUser.ip_addr)
        self.errors.add(:base, "IP address is banned")
        return false
      end
    end

    def unban!
      self.is_banned = false
      self.level = 20
      save
    end

    def ban_expired?
      is_banned? && recent_ban.try(:expired?)
    end
  end

  module NameMethods
    extend ActiveSupport::Concern

    module ClassMethods
      def name_to_id(name)
        Cache.fetch("uni:#{Cache.hash(name)}", 4.hours) do
          val = select_value_sql("SELECT id FROM users WHERE lower(name) = ?", name.downcase.tr(" ", "_").to_s)
          if val.present?
            val.to_i
          else
            nil
          end
        end
      end

      def name_or_id_to_id(name)
        if name =~ /\A!\d+\z/
          return name[1..-1].to_i
        end
        User.name_to_id(name)
      end

      def name_or_id_to_id_forced(name)
        if name =~ /\A\d+\z/
          return name.to_i
        end
        User.name_to_id(name)
      end

      def id_to_name(user_id)
        RequestStore[:id_name_cache] ||= {}
        if RequestStore[:id_name_cache].key?(user_id)
          return RequestStore[:id_name_cache][user_id]
        end
        name = Cache.fetch("uin:#{user_id}", 4.hours) do
          select_value_sql("SELECT name FROM users WHERE id = ?", user_id) || Danbooru.config.default_guest_name
        end
        RequestStore[:id_name_cache][user_id] = name
        name
      end

      def find_by_name(name)
        where("lower(name) = ?", name.downcase.tr(" ", "_")).first
      end

      def find_by_name_or_id(name)
        if name =~ /\A!\d+\z/
          where('id = ?', name[1..-1].to_i).first
        else
          find_by_name(name)
        end
      end

      def normalize_name(name)
        name.to_s.downcase.strip.tr(" ", "_").to_s
      end
    end

    def pretty_name
      name.gsub(/([^_])_+(?=[^_])/, "\\1 \\2")
    end

    def update_cache
      Cache.write("uin:#{id}", name, 4.hours)
      Cache.write("uni:#{Cache.hash(name)}", id, 4.hours)
    end
  end

  module PasswordMethods
    def password_token
      Zlib::crc32(bcrypt_password_hash)
    end

    def bcrypt_password
      BCrypt::Password.new(bcrypt_password_hash)
    end

    def encrypt_password_on_create
      return if Rails.env.test?
      self.password_hash = ""
      self.bcrypt_password_hash = User.bcrypt(password)
    end

    def encrypt_password_on_update
      return if password.blank?
      return if old_password.blank?

      if bcrypt_password == old_password
        self.bcrypt_password_hash = User.bcrypt(password)
        return true
      else
        errors.add(:old_password, "is incorrect")
        return false
      end
    end

    def upgrade_password(pass)
      self.update_columns(password_hash: '', bcrypt_password_hash: User.bcrypt(pass))
    end
  end

  module AuthenticationMethods
    extend ActiveSupport::Concern

    module ClassMethods
      def authenticate(name, pass)
        user = find_by_name(name)
        if Rails.env.test? && user && user.password_hash.present? && user.password_hash == pass
          return user
        end
        if user && user.password_hash.present? && Pbkdf2.validate_password(pass, user.password_hash)
          user.upgrade_password(pass)
          user
        elsif user && user.bcrypt_password_hash && user.bcrypt_password == pass
          user
        else
          nil
        end
      end

      def authenticate_api_key(name, api_key)
        key = ApiKey.where(:key => api_key).first
        return nil if key.nil?
        user = find_by_name(name)
        return nil if user.nil?
        return user if key.user_id == user.id
        nil
      end

      def bcrypt(pass)
        BCrypt::Password.create(pass)
      end
    end
  end

  module LevelMethods
    extend ActiveSupport::Concern

    module ClassMethods
      def system
        User.find_by!(name: Danbooru.config.system_user)
      end

      def anonymous
        user = User.new(name: "Anonymous", created_at: Time.now)
        user.level = Levels::ANONYMOUS
        user.freeze.readonly!
        user
      end

      def level_hash
        Danbooru.config.levels
      end

      def level_string(value)
        Danbooru.config.levels.invert[value] || ""
      end
    end

    def promote_to!(new_level, options = {})
      UserPromotion.new(self, CurrentUser.user, new_level, options).promote!
    end

    def level_string_was
      level_string(level_was)
    end

    def level_string(value = nil)
      User.level_string(value || level)
    end

    def is_anonymous?
      level == Levels::ANONYMOUS
    end

    def is_blocked?
      is_banned? || level == Levels::BLOCKED
    end

    # Defines various convenience methods for finding out the user's level
    Danbooru.config.levels.each do |name, value|
      # TODO: HACK: Remove this and make the below logic better to work with the new setup.
      next if [0, 10].include?(value)
      normalized_name = name.downcase.tr(' ', '_')
      define_method("is_exactly_#{normalized_name}?") do
        self.level == value && self.id.present?
      end

      # Changed from e6 to match new Danbooru semantics.
      define_method("is_#{normalized_name}?") do
        is_verified? && self.level >= value && self.id.present?
      end

      define_method("is_#{normalized_name}_or_higher?") do
        is_verified? && self.level >= value && self.id.present?
      end

      define_method("is_#{normalized_name}_or_lower?") do
        !is_verified? || (self.level <= value && self.id.present?)
      end
    end

    def is_voter?
      is_member?
    end

    def is_approver?
      can_approve_posts?
    end

    def set_per_page
      if per_page.nil?
        self.per_page = Danbooru.config.posts_per_page
      end

      return true
    end

    def blank_out_nonexistent_avatars
      if avatar_id.present? && avatar.nil?
        self.avatar_id = nil
      end
    end

    def staff_cant_disable_dmail
      self.disable_user_dmails = false if self.is_janitor?
    end

    def level_css_class
      "user-#{level_string.parameterize}"
    end

    def create_user_status
      UserStatus.create!(user_id: id)
    end
  end

  module EmailMethods
    def is_verified?
      id.present? && email_verification_key.nil?
    end

    def mark_unverified!
      update_attribute(:email_verification_key, '1')
    end

    def mark_verified!
      update_attribute(:email_verification_key, nil)
    end

    def enable_email_verification?
      # Allow admins to edit users with blank emails
      return false if email.blank? && !email_changed? && skip_email_blank_check
      Danbooru.config.enable_email_verification? && validate_email_format
    end

    def validate_email_address_allowed
      if EmailBlacklist.is_banned?(self.email)
        self.errors.add(:base, "Email address may not be used")
        return false
      end
    end
  end

  module BlacklistMethods
    def normalize_blacklisted_tags
      self.blacklisted_tags = TagAlias.to_aliased_query(blacklisted_tags.downcase) if blacklisted_tags.present?
    end

    def is_blacklisting_user?(user)
      return false if blacklisted_tags.blank?
      blta = blacklisted_tags.split("\n").map{|x| x.downcase}
      blta.include?("user:#{user.name.downcase}") || blta.include?("uploaderid:#{user.id}")
    end
  end

  module ForumMethods
    def has_forum_been_updated?
      return false unless is_member?
      max_updated_at = ForumTopic.permitted.active.order(updated_at: :desc).first&.updated_at
      return false if max_updated_at.nil?
      return true if last_forum_read_at.nil?
      return max_updated_at > last_forum_read_at
    end

    def has_viewed_thread?(id, last_updated)
      @topic_views ||= forum_topic_visits.pluck(:forum_topic_id, :last_read_at).to_h
      @topic_views.key?(id) && @topic_views[id] >= last_updated
    end
  end

  module ThrottleMethods
    def throttle_reason(reason)
      reasons = {
          REJ_NEWBIE: 'can not yet perform this action. Account is too new',
          REJ_LIMITED: 'have reached the hourly limit for this action'
      }
      reasons.fetch(reason, 'unknown throttle reason, please report this as a bug')
    end

    def upload_reason_string(reason)
      reasons = {
          REJ_UPLOAD_HOURLY: "have reached your hourly upload limit",
          REJ_UPLOAD_EDIT: "have no remaining tag edits available",
          REJ_UPLOAD_LIMIT: "have reached your upload limit",
          REJ_UPLOAD_NEWBIE: "cannot upload during your first week"
      }
      reasons.fetch(reason, "unknown upload rejection reason")
    end
  end

  module LimitMethods
    extend Memoist

    def younger_than(duration)
      return false if Danbooru.config.disable_age_checks?
      created_at > duration.ago
    end

    def older_than(duration)
      return true if Danbooru.config.disable_age_checks?
      created_at < duration.ago
    end

    def self.create_user_throttle(name, limiter, checker, newbie_duration)
      define_method("#{name}_limit".to_sym, limiter)

      define_method("can_#{name}_with_reason".to_sym) do
        return true if Danbooru.config.disable_throttles?
        return send(checker) if checker && send(checker)
        return :REJ_NEWBIE if newbie_duration && younger_than(newbie_duration)
        return :REJ_LIMITED if send("#{name}_limit") <= 0
        true
      end
    end

    def token_bucket
      @token_bucket ||= UserThrottle.new({prefix: "thtl:", duration: 1.minute}, self)
    end

    def general_bypass_throttle?
      is_privileged?
    end

    create_user_throttle(:artist_edit, ->{ Danbooru.config.artist_edit_limit - ArtistVersion.for_user(id).where('updated_at > ?', 1.hour.ago).count },
                         :general_bypass_throttle?, 7.days)
    create_user_throttle(:post_edit, ->{ Danbooru.config.post_edit_limit - PostVersion.for_user(id).where('updated_at > ?', 1.hour.ago).count },
                         :general_bypass_throttle?, 7.days)
    create_user_throttle(:wiki_edit, ->{ Danbooru.config.wiki_edit_limit - WikiPageVersion.for_user(id).where('updated_at > ?', 1.hour.ago).count },
                         :general_bypass_throttle?, 7.days)
    create_user_throttle(:pool, ->{ Danbooru.config.pool_limit - Pool.for_user(id).where('created_at > ?', 1.hour.ago).count },
                         :is_janitor?, 7.days)
    create_user_throttle(:pool_edit, ->{ Danbooru.config.pool_edit_limit - PoolVersion.for_user(id).where('updated_at > ?', 1.hour.ago).count },
                         :is_janitor?, 3.days)
    create_user_throttle(:pool_post_edit, -> { Danbooru.config.pool_post_edit_limit - PoolVersion.for_user(id).where('updated_at > ?', 1.hour.ago).group(:pool_id).count(:pool_id).length },
                          :general_bypass_throttle?, 7.days)
    create_user_throttle(:note_edit, ->{ Danbooru.config.note_edit_limit - NoteVersion.for_user(id).where('updated_at > ?', 1.hour.ago).count },
                         :general_bypass_throttle?, 3.days)
    create_user_throttle(:comment, ->{ Danbooru.config.member_comment_limit - Comment.for_creator(id).where('created_at > ?', 1.hour.ago).count },
                         :general_bypass_throttle?, 7.days)
    create_user_throttle(:forum_post, ->{ Danbooru.config.member_comment_limit - ForumPost.for_user(id).where('created_at > ?', 1.hour.ago).count },
                         nil, 3.days)
    create_user_throttle(:blip, ->{ Danbooru.config.blip_limit - Blip.for_creator(id).where('created_at > ?', 1.hour.ago).count },
                         :general_bypass_throttle?, 3.days)
    create_user_throttle(:dmail, ->{ Danbooru.config.dmail_limit - Dmail.sent_by_id(id).where('created_at > ?', 1.hour.ago).count },
                         nil, 7.days)
    create_user_throttle(:dmail_minute, ->{ Danbooru.config.dmail_minute_limit - Dmail.sent_by_id(id).where('created_at > ?', 1.minute.ago).count },
                         nil, 7.days)
    create_user_throttle(:comment_vote, ->{ Danbooru.config.comment_vote_limit - CommentVote.for_user(id).where("created_at > ?", 1.hour.ago).count },
                         :general_bypass_throttle?, 3.days)
    create_user_throttle(:post_vote, ->{ Danbooru.config.post_vote_limit - PostVote.for_user(id).where("created_at > ?", 1.hour.ago).count },
                         :general_bypass_throttle?, nil)
    create_user_throttle(:post_flag, ->{ Danbooru.config.post_flag_limit - PostFlag.for_creator(id).where("created_at > ?", 1.hour.ago).count },
                         :can_approve_posts?, 3.days)
    create_user_throttle(:ticket, ->{ Danbooru.config.ticket_limit - Ticket.for_creator(id).where("created_at > ?", 1.hour.ago).count },
                         :general_bypass_throttle?, 3.days)
    create_user_throttle(:suggest_tag, -> { Danbooru.config.tag_suggestion_limit - (TagAlias.for_creator(id).where("created_at > ?", 1.hour.ago).count + TagImplication.for_creator(id).where("created_at > ?", 1.hour.ago).count + BulkUpdateRequest.for_creator(id).where("created_at > ?", 1.hour.ago).count) },
                         :is_janitor?, 7.days)
    create_user_throttle(:forum_vote, -> { Danbooru.config.forum_vote_limit - ForumPostVote.by(id).where("created_at > ?", 1.hour.ago).count },
                         :is_janitor?, 3.days)

    def can_remove_from_pools?
      is_member? && older_than(7.days)
    end

    def can_discord?
      is_member? && older_than(7.days)
    end

    def can_view_flagger?(flagger_id)
      is_janitor? || flagger_id == id
    end

    def can_view_flagger_on_post?(flag)
      is_janitor? || flag.creator_id == id || flag.is_deletion
    end

    def can_replace?
      is_janitor? || replacements_beta?
    end

    def can_view_staff_notes?
      is_janitor?
    end

    def can_upload?
      can_upload_with_reason == true
    end

    def can_upload_with_reason
      if hourly_upload_limit <= 0 && !Danbooru.config.disable_throttles?
        :REJ_UPLOAD_HOURLY
      elsif can_upload_free? || is_admin?
          true
      elsif younger_than(7.days)
        :REJ_UPLOAD_NEWBIE
      elsif !is_privileged? && post_edit_limit <= 0 && !Danbooru.config.disable_throttles?
        :REJ_UPLOAD_EDIT
      elsif upload_limit <= 0 && !Danbooru.config.disable_throttles?
        :REJ_UPLOAD_LIMIT
      else
        true
      end
    end

    def hourly_upload_limit
      Danbooru.config.hourly_upload_limit - Post.for_user(id).where("created_at >= ?", 1.hour.ago).count
    end
    memoize :hourly_upload_limit

    def upload_limit
      pieces = upload_limit_pieces

      base_upload_limit + (pieces[:approved] / 10) - (pieces[:deleted] / 4) - pieces[:pending]
    end
    memoize :upload_limit

    def upload_limit_pieces
      deleted_count = Post.deleted.for_user(id).count
      rejected_replacement_count = post_replacement_rejected_count
      replaced_penalize_count = own_post_replaced_penalize_count
      unapproved_count = Post.pending_or_flagged.for_user(id).count
      unapproved_replacements_count = PostReplacement.pending.for_user(id).count
      approved_count = Post.for_user(id).where('is_flagged = false AND is_deleted = false AND is_pending = false').count

      {
        deleted: deleted_count + replaced_penalize_count + rejected_replacement_count,
        deleted_ignore: own_post_replaced_count - replaced_penalize_count,
        approved: approved_count,
        pending: unapproved_count + unapproved_replacements_count
      }
    end
    memoize :upload_limit_pieces

    def post_upload_throttle
      return hourly_upload_limit if is_privileged_or_higher?
      [hourly_upload_limit, post_edit_limit].min
    end
    memoize :post_upload_throttle

    def tag_query_limit
      Danbooru.config.tag_query_limit
    end

    def favorite_limit
      if is_contributor?
        250_000
      elsif is_privileged?
        125_000
      else
        80_000
      end
    end

    def api_regen_multiplier
      1
    end

    def api_burst_limit
      # can make this many api calls at once before being bound by
      # api_regen_multiplier refilling your pool
      if is_contributor?
        120
      elsif is_privileged?
        90
      else
        60
      end
    end

    def remaining_api_limit
      token_bucket.uncached_count
    end

    def statement_timeout
      if is_contributor?
        9_000
      elsif is_privileged?
        6_000
      else
        3_000
      end
    end
  end

  module ApiMethods
    # blacklist all attributes by default. whitelist only safe attributes.
    def hidden_attributes
      super + attributes.keys.map(&:to_sym)
    end

    def method_attributes
      list = super + [
        :id, :created_at, :name, :level, :base_upload_limit,
        :post_upload_count, :post_update_count, :note_update_count,
        :is_banned, :can_approve_posts, :can_upload_free,
        :level_string, :avatar_id
      ]

      if id == CurrentUser.user.id
        list += BOOLEAN_ATTRIBUTES + [
          :updated_at, :email, :last_logged_in_at, :last_forum_read_at,
          :recent_tags, :comment_threshold, :default_image_size,
          :favorite_tags, :blacklisted_tags, :time_zone, :per_page,
          :custom_style, :favorite_count,
          :api_regen_multiplier, :api_burst_limit, :remaining_api_limit,
          :statement_timeout, :favorite_limit,
          :tag_query_limit
        ]
      end

      list
    end

    # extra attributes returned for /users/:id.json but not for /users.json.
    def full_attributes
      [
        :wiki_page_version_count, :artist_version_count, :pool_version_count,
        :forum_post_count, :comment_count,
        :flag_count, :favorite_count, :positive_feedback_count,
        :neutral_feedback_count, :negative_feedback_count, :upload_limit
      ]
    end
  end

  module CountMethods
    def wiki_page_version_count
      user_status.wiki_edit_count
    end

    def post_update_count
      user_status.post_update_count
    end

    def post_upload_count
      user_status.post_count
    end

    def post_deleted_count
      user_status.post_deleted_count
    end

    def note_version_count
      user_status.note_count
    end

    def note_update_count
      note_version_count
    end

    def artist_version_count
      user_status.artist_edit_count
    end

    def pool_version_count
      user_status.pool_edit_count
    end

    def forum_post_count
      user_status.forum_post_count
    end

    def favorite_count
      user_status.favorite_count
    end

    def comment_count
      user_status.comment_count
    end

    def flag_count
      user_status.post_flag_count
    end

    def positive_feedback_count
      feedback.positive.count
    end

    def neutral_feedback_count
      feedback.neutral.count
    end

    def negative_feedback_count
      feedback.negative.count
    end

    def post_replacement_rejected_count
      user_status.post_replacement_rejected_count
    end

    def own_post_replaced_count
      user_status.own_post_replaced_count
    end

    def own_post_replaced_penalize_count
      user_status.own_post_replaced_penalize_count
    end

    def refresh_counts!
      self.class.without_timeout do
        UserStatus.where(user_id: id).update_all(
          post_count: Post.for_user(id).count,
          post_deleted_count: Post.for_user(id).deleted.count,
          post_update_count: PostVersion.for_user(id).count,
          note_count: NoteVersion.where(updater_id: id).count
        )
      end
    end
  end

  module SearchMethods
    def admins
      where("level = ?", Levels::ADMIN)
    end

    def with_email(email)
      if email.blank?
        where("FALSE")
      else
        where("lower(email) = lower(?)", email)
      end
    end

    def search(params)
      q = super
      q = q.joins(:user_status)

      params = params.dup
      params[:name_matches] = params.delete(:name) if params[:name].present?

      q = q.search_text_attribute(:name, params)
      q = q.attribute_matches(:level, params[:level])
      # TODO: Doesn't support relation filtering using this method.
      # q = q.attribute_matches(:post_upload_count, params[:post_upload_count])
      # q = q.attribute_matches(:post_update_count, params[:post_update_count])
      # q = q.attribute_matches(:note_update_count, params[:note_update_count])
      # q = q.attribute_matches(:favorite_count, params[:favorite_count])

      if params[:email_matches].present?
        q = q.where_ilike(:email, params[:email_matches])
      end

      if params[:name_matches].present?
        q = q.where_ilike(:name, normalize_name(params[:name_matches]))
      end

      if params[:min_level].present?
        q = q.where("level >= ?", params[:min_level].to_i)
      end

      if params[:max_level].present?
        q = q.where("level <= ?", params[:max_level].to_i)
      end

      bitprefs_length = BOOLEAN_ATTRIBUTES.length
      bitprefs_include = nil
      bitprefs_exclude = nil

      [:can_approve_posts, :can_upload_free].each do |x|
        if params[x].present?
          attr_idx = BOOLEAN_ATTRIBUTES.index(x.to_s)
          if params[x].to_s.truthy?
            bitprefs_include ||= "0"*bitprefs_length
            bitprefs_include[attr_idx] = '1'
          elsif params[x].to_s.falsy?
            bitprefs_exclude ||= "0"*bitprefs_length
            bitprefs_exclude[attr_idx] = '1'
          end
        end
      end

      if bitprefs_include
        bitprefs_include.reverse!
        q = q.where("bit_prefs::bit(:len) & :bits::bit(:len) = :bits::bit(:len)",
                    {:len => bitprefs_length, :bits => bitprefs_include})
      end

      if bitprefs_exclude
        bitprefs_exclude.reverse!
        q = q.where("bit_prefs::bit(:len) & :bits::bit(:len) = 0::bit(:len)",
                    {:len => bitprefs_length, :bits => bitprefs_exclude})
      end

      if params[:ip_addr].present?
        q = q.where("last_ip_addr <<= ?", params[:ip_addr])
      end

      case params[:order]
      when "name"
        q = q.order("name")
      when "post_upload_count"
        q = q.order("user_statuses.post_count desc")
      when "note_count"
        q = q.order("user_statuses.note_count desc")
      when "post_update_count"
        q = q.order("user_statuses.post_update_count desc")
      else
        q = q.apply_default_order(params)
      end

      q
    end
  end

  concerning :SockPuppetMethods do
    def validate_sock_puppets
      if User.where(last_ip_addr: CurrentUser.ip_addr).where("created_at > ?", 1.day.ago).exists?
        errors.add(:last_ip_addr, "was used recently for another account and cannot be reused for another day")
      end
    end
  end

  include BanMethods
  include NameMethods
  include PasswordMethods
  include AuthenticationMethods
  include LevelMethods
  include EmailMethods
  include BlacklistMethods
  include ForumMethods
  include LimitMethods
  include ApiMethods
  include CountMethods
  extend SearchMethods
  extend ThrottleMethods

  def dmail_count
    if has_mail?
      "(#{unread_dmail_count})"
    else
      ""
    end
  end

  def hide_favorites?
    return false if CurrentUser.is_moderator?
    return true if is_blocked?
    enable_privacy_mode? && CurrentUser.user.id != id
  end

  def compact_uploader?
    post_upload_count >= 10 && enable_compact_uploader?
  end

  def initialize_attributes
    self.last_ip_addr ||= CurrentUser.ip_addr

    return if Rails.env.test?
    Danbooru.config.customize_new_user(self)
  end

  def presenter
    @presenter ||= UserPresenter.new(self)
  end
end
