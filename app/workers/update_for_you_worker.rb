# frozen_string_literal: true

class UpdateForYouWorker
  include Redisable
  include Sidekiq::Worker

  sidekiq_options retry: 0, queue: 'pull'

  # Mammoth Curated List(OG List)

  #  Fetch Acct Config from AcctRelay
  #  Fetch Following from AcctRelay
  #  Then status of those accounts from following locally
  #  Finally send them to for_you_feed_worker
  def perform(opts)
    @personal = PersonalForYou.new
    @acct = opts['acct']
    @user = mammoth_user(@acct).wait
    # This is temperary
    @account = local_account

    # Unable to resolve account
    # Set Status to 'error'
    if @account.nil?
      update_user_status('error').wait
      ResolveAccountWorker.perform_async(@acct)
      return nil
    end

    # If rebuild is true, Zero Out User's for you feed
    @personal.reset_feed(@account.id) if opts['rebuild']

    push_status!

    # Final Step:
    # Set user's status to 'idle'
    update_user_status('idle').wait
  end

  private

  def push_status!
    # Indirect Follow
    push_indirect_following_status
    # Direct Follows
    push_following_status
    # Channel Feed
    push_channels_status
    # Mammoth Curated OG Feed
    push_mammoth_curated_status
  end

  def update_user_status(status)
    Async do
      @personal.update_user(@acct, { status: status })
    end
  end

  def local_account
    domain = @user[:domain] == ENV['LOCAL_DOMAIN'] ? nil : @user[:domain]
    Account.where(username: @user[:username], domain: domain).first
  end

  def mammoth_user(acct)
    Async do
      @personal.user(acct)
    end
  end

  # TODO: update account.id to user.acct
  # Return early if user setting is Zero, meaning 'off' from the iOS perspective
  def push_following_status
    user_setting = @user[:for_you_settings]
    return if user_setting[:your_follows].zero?

    @personal.statuses_for_direct_follows(@acct)
             .filter_map { |s| engagment_threshold(s, user_setting[:your_follows], 'following') }
             .each { |s| ForYouFeedWorker.perform_async(s['id'], @account.id, 'personal') }
  end

  # Indirect Follows
  def push_indirect_following_status
    user_setting = @user[:for_you_settings]
    return if user_setting[:friends_of_friends].zero?

    @personal.statuses_for_indirect_follows(@account)
             .filter_map { |s| engagment_threshold(s, user_setting[:friends_of_friends], 'indirect') }
             .each { |s| ForYouFeedWorker.perform_async(s['id'], @account.id, 'personal') }
  end

  # Channels Subscribed
  def push_channels_status
    user_setting = @user[:for_you_settings]
    return if user_setting[:from_your_channels].zero?

    @personal.statuses_for_subscribed_channels(@user)
             .filter_map { |s| engagment_threshold(s, user_setting[:from_your_channels], 'channel') }
             .each { |s| ForYouFeedWorker.perform_async(s['id'], @account.id, 'personal') }
  end

  # Mammoth Curated OG List
  def push_mammoth_curated_status
    user_setting = @user[:for_you_settings]
    return if user_setting[:curated_by_mammoth].zero?

    curated_list = Mammoth::CuratedList.new
    list_statuses = curated_list.curated_list_statuses

    Rails.logger.info "THE LIST OF STATUSES>>>>> #{list_statuses.inspect}"

    list_statuses.filter_map { |s| engagment_threshold(s, user_setting[:curated_by_mammoth], 'mammoth') }
                 .each { |s| ForYouFeedWorker.perform_async(s['id'], @account.id, 'personal') }
  end

  # Check status for User's level of engagment
  # Filter out polls and replys
  def engagment_threshold(wrapped_status, user_engagment_setting, type)
    # enagagment threshold
    engagment = engagment_metrics(type)
    status = wrapped_status.reblog? ? wrapped_status.reblog : wrapped_status

    status_counts = status.reblogs_count + status.replies_count + status.favourites_count
    status if status_counts >= engagment[user_engagment_setting] && status.in_reply_to_id.nil? && status.poll_id.nil?
  end

  # Threshold setttings variation for each specific branch of the for you feed
  # 1,2,3 relates to low,med, high and it's respectice value as it relates to engagment
  def engagment_metrics(type)
    case type
    when 'following', 'mammoth'
      { 1 => 2, 2 => 4, 3 => 6 }
    when 'channel'
      { 1 => 0, 2 => 1, 3 => 2 }
    when 'indirect'
      { 1 => 1, 2 => 2, 3 => 3 }
    end
  end

  def mammoth_curated_list_statuses
    Rails.logger.info "List ForYou>>>>>>>>>>> \n NOW"
    username = ENV['FOR_YOU_OWNER_ACCOUNT'] || 'admin'
    list_title = 'For You'
    owner_account = Account.local.where(username: username)
    @list = List.where(account: owner_account, title: list_title).first!
    Rails.logger.info "List ForYou>>>>>>>>>>> \n #{@list.inspect}"
    list_feed.get(1000)
  end

  def list_feed
    ListFeed.new(@list)
  end
end
