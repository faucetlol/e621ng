module PostSetPresenters
  class Post < Base
    attr_accessor :post_set
    delegate :posts, to: :post_set
    delegate :post_index_sidebar_tag_list_html, to: :tag_set_presenter

    def initialize(post_set)
      @post_set = post_set
    end

    def tag_set_presenter
      @tag_set_presenter ||= TagSetPresenter.new(related_tags)
    end

    def post_previews_html(template, options = {})
      super(template, options.merge(show_cropped: true))
    end

    def related_tags
      if post_set.is_pattern_search?
        pattern_tags
      elsif post_set.is_empty_tag? || post_set.tag_string == "order:rank"
        popular_tags
      elsif post_set.is_single_tag?
        related_tags_for_single(post_set.tag_string)
      elsif post_set.unordered_tag_array.size == 1
        related_tags_for_single(post_set.unordered_tag_array.first)
      elsif Tag.has_metatag?(post_set.tag_array, *Tag::SUBQUERY_METATAGS)
        calculate_related_tags_from_post_set
      else
        related_tags_for_group
      end
    end

    def popular_tags
      Tag.trending
    end

    def pattern_tags
      Tag.name_matches(post_set.tag_string).select("name").limit(Danbooru.config.tag_query_limit).order("post_count DESC").map(&:name)
    end

    def related_tags_for_group
      RelatedTagCalculator.calculate_from_sample_to_array(post_set.tag_string).map(&:first)
    end

    def related_tags_for_single(tag_string)
      tag = Tag.find_by_name(tag_string.downcase)

      if tag
        tag.related_tag_array.map(&:first)
      else
        calculate_related_tags_from_post_set
      end
    end

    def calculate_related_tags_from_post_set
      RelatedTagCalculator.calculate_from_posts_to_array(post_set.posts).map(&:first)
    end
  end
end
