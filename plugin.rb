# name: babble
# about: Shoutbox plugin for Discourse
# version: 1.1.0
# authors: James Kiesel (gdpelican)
# url: https://github.com/gdpelican/babble

register_asset "stylesheets/babble.scss"

BABBLE_PLUGIN_NAME ||= "babble".freeze

enabled_site_setting :babble_enabled

after_initialize do
  module ::Babble
    class Engine < ::Rails::Engine
      engine_name BABBLE_PLUGIN_NAME
      isolate_namespace Babble
    end
  end

  Babble::Engine.routes.draw do
    get    "/topics"                       => "topics#index"
    post   "/topics"                       => "topics#create"
    get    "/topics/default"               => "topics#default"
    get    "/topics/:id"                   => "topics#show"
    post   "/topics/:id"                   => "topics#update"
    delete "/topics/:id"                   => "topics#destroy"
    get    "/topics/:id/read/:post_number" => "topics#read"
    post   "/topics/:id/post"              => "topics#create_post"
    post   "/topics/:id/post/:post_id"     => "topics#update_post"
    delete "/topics/:id/destroy/:post_id"  => "topics#destroy_post"
    get    "/topics/:id/groups"            => "topics#groups"
    post   "/topics/:id/notification"      => "topics#send_notification"
  end

  Discourse::Application.routes.append do
    mount ::Babble::Engine, at: "/babble", :as => "babble"
    get '/chat/:slug/:id' => 'babble/topics#show'
    namespace :admin, constraints: StaffConstraint.new do
      resources :chats, only: [:show, :index]
    end
  end

  class ::Admin::ChatsController < ::ApplicationController
    requires_plugin BABBLE_PLUGIN_NAME
    define_method :index, ->{}
    define_method :show, ->{}
  end

  Category.register_custom_field_type('chat_topic_id', :integer)
  add_to_serializer(:basic_category, :chat_topic_id) { object.custom_fields['chat_topic_id'] unless object.custom_fields['chat_topic_id'].to_i == 0 }
  add_to_serializer(:basic_topic, :category_id)      { object.category_id }

  require_dependency "application_controller"
  class ::Babble::TopicsController < ::ApplicationController
    requires_plugin BABBLE_PLUGIN_NAME
    before_filter :ensure_logged_in
    before_filter :set_default_id, only: :default

    def index
      if current_user.blank?
        respond_with_forbidden
      else
        respond_with Babble::Topic.available_topics_for(current_user), serializer: BasicTopicSerializer
      end
    end

    def show
      perform_fetch do
        TopicUser.find_or_create_by(user: current_user, topic: topic)
        respond_with topic_view, serializer: Babble::TopicViewSerializer
      end
    end
    alias :default :show

    def create
      perform_update { @topic = Babble::Topic.save_topic(topic_params) }
    end

    def update
      perform_update { Babble::Topic.save_topic(topic_params, topic) }
    end

    def destroy
      if !current_user.admin?
        respond_with_forbidden
      elsif topic.ordered_posts.any?
        Babble::PostDestroyer.new(current_user, topic.ordered_posts.first).destroy
        respond_with nil
      else
        Babble::Topic.destroy_topic(topic)
        respond_with nil
      end
    end

    def read
      perform_fetch do
        topic_user.update(last_read_post_number: params[:post_number]) if topic_user.last_read_post_number.to_i < params[:post_number].to_i
        respond_with topic_view, serializer: Babble::TopicViewSerializer
      end
    end

    def create_post
      perform_fetch do
        @post = Babble::PostCreator.create(current_user, post_creator_params)
        if @post.persisted?
          success_callback
          respond_with @post, serializer: Babble::PostSerializer
        else
          respond_with_unprocessable
        end
      end
    end

    def success_callback
      if (SiteSetting.babble_remote_post)
        RestClient.post(SiteSetting.babble_remote_url, { current_user: current_user.username, message: @post.cooked }) unless params[:skip_callback]
      end
    end

    def update_post
      perform_fetch do
        if !guardian.can_edit_post?(topic_post)
          respond_with_forbidden
        elsif Babble::PostRevisor.new(topic_post, topic).revise!(current_user, params.slice(:raw))
          respond_with topic_post, serializer: Babble::PostSerializer
        else
          respond_with_unprocessable
        end
      end
    end

    def destroy_post
      perform_fetch do
        if !guardian.can_delete_post?(topic_post)
          respond_with_forbidden
        else
          Babble::PostDestroyer.new(current_user, topic_post).destroy
          respond_with topic_post, serializer: Babble::PostSerializer
        end
      end
    end

    def groups
      perform_fetch(require_admin: true) { respond_with topic.allowed_groups, serializer: BasicGroupSerializer }
    end

    def send_notification
      perform_fetch do
        Babble::Broadcaster.publish_to_notifications(topic, current_user, notification_params)
        respond_with nil
      end
    end

    private

    def set_default_id
      params[:id] = Babble::Topic.default_topic_for(current_user).try(:id)
    end

    def perform_fetch(require_admin: false)
      if topic.blank?
        respond_with_not_found
      elsif !current_user.admin && (require_admin || !Babble::Topic.available_topics_for(current_user).include?(topic))
        respond_with_forbidden
      else
        yield
      end
    end

    def perform_update
      if !current_user.admin?
        respond_with_forbidden
      elsif !yield
        respond_with_unprocessable
      else
        respond_with topic_view, serializer: Babble::TopicViewSerializer
      end
    end

    def respond_with(object, serializer: nil)
      case object
      when Array, ActiveRecord::Relation
        render json: ActiveModel::ArraySerializer.new(object, each_serializer: serializer, scope: guardian, root: false).as_json
      when nil
        render json: { success: :ok }
      else
        render json: serializer.new(object, scope: guardian, root: false).as_json
      end
    end

    def respond_with_unprocessable
      render json: { errors: 'Unable to create or update post' }, status: :unprocessable_entity
    end

    def respond_with_forbidden
      render json: { errors: 'You are unable to view this chat topic' }, status: :forbidden
    end

    def respond_with_not_found
      render json: { errors: 'Chat topic not found' }, status: :not_found
    end

    def topic
      @topic ||= begin
        if params[:id]
          Babble::Topic.find(id: params[:id])
        elsif params[:category]
          Babble::Topic.find(category_id: Category.find_by(slug: params[:category]))
        end
      end
    end

    def topic_post
      @topic_post ||= Post.find_by(id: params[:post_id])
    end

    def topic_user
      @topic_user ||= TopicUser.find_or_initialize_by(user: current_user, topic: topic)
    end

    def topic_view
      opts = { post_number: topic.highest_post_number } if topic.highest_post_number > 0
      @topic_view ||= TopicView.new(topic.id, current_user, opts || {})
    end

    def topic_params
      params.require(:topic).permit(:title, :permissions, :category_id, allowed_group_ids: [])
    end

    def post_creator_params
      {
        topic_id:         params[:id],
        raw:              params[:raw],
        skip_validations: true
      }
    end

    def notification_params
      params.require(:state)
    end
  end

  class ::Babble::PostCreator < ::PostCreator

    def self.create(user, opts)
      Babble::PostCreator.new(user, opts).create
    end

    def valid?
      setup_post
      errors.add :base, "No post content" unless @post.raw.present?
      errors.empty?
    end

    def setup_post
      super
      @topic = @post.topic = Topic.find_by(id: @opts[:topic_id])
    end

    def update_user_counts
      return false
    end

    def enqueue_jobs
      return false
    end

    def trigger_after_events(post)
      super

      TopicUser.update_last_read(@user, @topic.id, @post.post_number, PostTiming::MAX_READ_TIME_PER_BATCH)
      Babble::Topic.prune_topic(@topic)

      Babble::Broadcaster.publish_to_posts(@post, @user)
      Babble::Broadcaster.publish_to_topic(@topic, @user)
    end
  end

  class ::Babble::PostRevisor < ::PostRevisor

    def revise!(editor, fields, opts={})
      return false unless fields[:raw].present? && @post.topic == @topic
      opts[:validate_post] = false # don't validate length etc of chat posts
      super
    end

    private

    def publish_changes
      super
      Babble::Broadcaster.publish_to_posts(@post, @editor, is_edit: true)
    end
  end

  class ::Babble::PostDestroyer < ::PostDestroyer
    def destroy
      super
      Babble::Broadcaster.publish_to_topic(@topic, @user)
      Babble::Broadcaster.publish_to_posts(@post, @user, is_delete: true)
    end
  end

  class Babble::Broadcaster

    def self.publish_to_topic(topic, user, extras = {})
      MessageBus.publish "/babble/topics/#{topic.id}", serialized_topic(topic, user, extras)
    end

    def self.publish_to_posts(post, user, extras = {})
      MessageBus.publish "/babble/topics/#{post.topic_id}/posts", serialized_post(post, user, extras)
    end

    def self.publish_to_notifications(topic, user, status)
      MessageBus.publish "/babble/topics/#{topic.id}/notifications", serialized_notification(user, {status: status})
    end

    def self.serialized_topic(topic, user, extras = {})
      serialize(Babble::AnonymousTopicView.new(topic.id, user), user, extras, Babble::TopicViewSerializer)
    end

    def self.serialized_post(post, user, extras = {})
      serialize(post, user, extras, Babble::PostSerializer).as_json.merge(extras)
    end

    def self.serialized_notification(user, extras = {})
      UserSerializer.new(user, scope: Guardian.new).as_json.merge(extras)
    end

    def self.serialize(obj, user, extras, serializer)
      serializer.new(obj, scope: Guardian.new(user), root: false).as_json.merge(extras)
    end
  end

  class ::Babble::Topic

    def self.save_topic(params, topic = Topic.new)
      case params.fetch(:permissions, 'group')
      when 'category'
        category = Category.find(params[:category_id])
        return false if params[:allowed_group_ids].present?
        return false if category.custom_fields['chat_topic_id'].to_i != 0 # don't allow multiple channels on a single category
        params[:allowed_groups] = Group.none
        params[:title]        ||= category.name
      when 'group'
        return false if params[:category_id].present? || !params[:title].present?
        params[:allowed_groups] = get_allowed_groups(params[:allowed_group_ids])
        params[:category_id] = nil
      end

      topic.tap do |t|
        t.assign_attributes archetype: :chat, user_id: Discourse::SYSTEM_USER_ID, last_post_user_id: Discourse::SYSTEM_USER_ID
        t.assign_attributes params.except(:permissions, :allowed_group_ids)
        if t.valid? || t.errors.to_hash.except(:title).empty?
          t.save(validate: false)
          update_category(params[:category_id], t.reload.id) if params[:category_id]
        end
      end
    end

    def self.destroy_topic(topic)
      topic.tap { |t| update_category(topic.category_id, nil) if topic.category_id }.destroy
    end

    def self.update_category(category_id, topic_id)
      Category.find(category_id).tap { |c| c.custom_fields['chat_topic_id'] = topic_id }.save
    end

    def self.get_allowed_groups(ids)
      Group.where(id: Array(ids)).presence || default_allowed_groups
    end

    def self.set_default_allowed_groups(topic)
      topic.allowed_group_ids << default_allowed_groups unless topic.allowed_groups.any?
    end

    def self.default_allowed_groups
      Group.find Array Group::AUTO_GROUPS[:trust_level_0]
    end

    def self.prune_topic(topic)
      topic.posts.order(created_at: :desc).offset(SiteSetting.babble_max_topic_size).destroy_all
      topic.update(user: Discourse.system_user)
    end

    def self.default_topic_for(user)
      available_topics_for(user).first
    end

    def self.available_topics
      Topic.where(archetype: :chat).includes(:allowed_groups)
    end

    def self.available_topics_for(user)
      guardian = Guardian.new(user)
      available_topics.select { |topic| guardian.can_see?(topic) }
    end

    # NB: the set_default_allowed_groups block is passed for backwards compatibility,
    # so that we never have a topic which has no allowed groups.
    def self.find(param)
      available_topics.find_by(param).tap { |topic| set_default_allowed_groups(topic) if topic }
    end
  end

  # anonymous topic_view for sending out via Message Bus
  # (otherwise we end up serializing out the current user's read data to other people)
  class ::Babble::AnonymousTopicView < ::TopicView
    def topic_user
      nil
    end
  end

  class ::Babble::PostSerializer < ::PostSerializer
    attributes :image_count

    def initialize(object, opts = {})
      super object, opts.merge(add_raw: true)
    end
  end

  class ::Babble::TopicViewSerializer < ::TopicViewSerializer
    attributes :group_names, :last_posted_at, :permissions
    def group_names
      object.topic.allowed_groups.pluck(:name).map(&:humanize)
    end

    def permissions
      [nil, Babble::Category.instance.id].include?(object.topic.category_id) ? 'group' : 'category'
    end

    def posts
      @posts ||= object.posts.map do |p|
        ps = Babble::PostSerializer.new(p, scope: scope, root: false)
        ps.topic_view = object
        ps.as_json
      end
    end

    def last_read_post_number
      super || 0
    end

    private

    def include_group_names?
      permissions == 'group'
    end

    # details are expensive to calculate and we don't use them
    def include_details?
      false
    end
  end

  class ::Babble::Category
    def self.instance
      Category.find_by(name: SiteSetting.babble_category_name) ||
      Category.new(    name: SiteSetting.babble_category_name,
                       slug: SiteSetting.babble_category_name,
                       user: Discourse.system_user).tap { |t| t.save(validate: false) }
    end
  end

  class ::Guardian
    module CanSeeTopic
      def can_see_topic?(topic, hide_deleted=true)
        super || topic.archetype == Archetype.chat && (can_see?(topic.category) || topic.allowed_group_users.include?(user))
      end
    end
    prepend CanSeeTopic
  end

  class ::Archetype
    def self.chat
      'chat'
    end
  end

  class ::TopicQuery
    module DefaultResults
      def default_results(options={})
        super(options).where('archetype <> ?', Archetype.chat)
      end
    end
    prepend DefaultResults
  end
end
