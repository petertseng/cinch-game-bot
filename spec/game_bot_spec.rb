require 'simplecov'
SimpleCov.start { add_filter '/spec/' }

require 'cinch/test'
require 'cinch/plugins/game_bot'
require 'example_plugin'

RSpec.configure { |c|
  c.warnings = true
  c.disable_monkey_patching!
}

def get_replies_text(m)
  replies = get_replies(m)
  # If you wanted, you could read all the messages as they come, but that might be a bit much.
  # You'd want to check the messages of user1, user2, and chan as well.
  # replies.each { |x| puts(x.text) }
  replies.map(&:text)
end

class MessageReceiver
  attr_reader :name
  attr_accessor :messages

  def initialize(name)
    @name = name
    @messages = []
  end

  def send(m)
    @messages << m
  end
end

class TestChannel < MessageReceiver
  def voiced
    []
  end
  def devoice(_)
  end
  def moderated=(_)
  end
end

RSpec.describe Cinch::Plugins::GameBot do
  include Cinch::Test

  let(:channel1) { '#test' }
  let(:chan) { TestChannel.new(channel1) }
  let(:bogus_channel) { '#bogus' }
  let(:player1) { 'test1' }
  let(:player2) { 'test2' }
  let(:player3) { 'test3' }
  let(:player4) { 'test4' }
  let(:players) { [
    player1,
    player2,
    player3,
    player4,
  ]}

  let(:opts) {{
    :channels => [channel1],
    :settings => '/dev/null',
    :mods => [player1],
  }}
  let(:bot) {
    make_bot(Cinch::Plugins::ExamplePlugin, opts) { |c| c.loggers.first.level = :warn }
  }
  let(:plugin) { bot.plugins.first }

  def msg(text, nick: player1, channel: channel1)
    return make_message(bot, text, nick: nick) unless channel
    make_message(bot, text, nick: nick, channel: channel)
  end
  def authed_msg(text, nick: player1, channel: channel1)
    m = msg(text, nick: nick, channel: channel)
    allow(m.user).to receive(:authed?).and_return(true)
    allow(m.user).to receive(:authname).and_return(nick)
    m
  end

  def join(message)
    expect(message.channel).to receive(:has_user?).with(message.user).and_return(true)
    expect(message.channel).to receive(:voice).with(message.user)
    get_replies(message)
  end

  it 'makes a test bot' do
    expect(bot).to be_a(Cinch::Bot)
  end

  describe '!join' do
    it 'lets a single player join' do
      replies = join(msg('!join', nick: player1)).map(&:text)
      expect(replies).to be == ["#{player1} has joined the game (1/3)"]
    end

    it 'allows join via PM' do
      m = msg("!join #{channel1}", nick: player1, channel: nil)
      # These at_least(1) are just because of the cinch-test bug (double reply to PM)
      # They can be removed if cinch-test releases a new version.
      expect(plugin).to receive(:Channel).with(channel1).at_least(1).and_return(chan)
      expect(chan).to receive(:has_user?).with(m.user).at_least(1).and_return(true)
      expect(chan).to receive(:voice).with(m.user).at_least(1)
      # NB: because of the aforementioned bug, replies actually contains a "You are already in the #channel game"!
      # We will obviously not test this behavior.
      get_replies(m)
      expect(chan.messages).to be == ["#{player1} has joined the game (1/3)"]
    end

    it 'requires channel argument by PM' do
      m = msg("!join", nick: player1, channel: nil)
      replies = get_replies_text(m)
      # cinch-test double-reply bug means we can't check that count is exactly equal to one.
      expect(replies).to_not be_empty
      expect(replies).to be_all { |r| r =~ /must specify the channel/ }
    end

    it 'requires channel presence' do
      replies = get_replies_text(msg('!join', nick: player1))
      expect(replies).to be == ["#{player1}: You need to be in #{channel1} to join the game."]
    end

    it 'disallows double joins' do
      first_message = msg('!join', nick: player1)
      join(first_message)
      # We need to mess with Cinch::User.new because cinch-test is messing with us.
      # (creating users who are eql? but whose hash are not the same)
      expect(Cinch::User).to receive(:new).with(player1, anything).and_return(first_message.user)
      replies = get_replies_text(msg('!join', nick: player1))
      expect(replies).to be == ["#{player1}: You are already in the #{channel1} game"]
    end

    it 'disallows bogus channel' do
      replies = get_replies_text(msg('!join', nick: player1, channel: bogus_channel))
      expect(replies).to be == ["#{player1}: #{bogus_channel} is not a valid channel to join"]
    end

    it 'disallows joining started game' do
      join(msg('!join', nick: player1))
      join(msg('!join', nick: player2))
      get_replies(msg('!start'))
      m = msg('!join', nick: player3)
      expect(m.channel).to receive(:has_user?).with(m.user).and_return(true)
      replies = get_replies_text(m)
      expect(replies).to be == ["#{player3}: Game has already started."]
    end

    it 'disallows double-joining started game' do
      first_message = msg('!join', nick: player1)
      join(first_message)
      join(msg('!join', nick: player2))
      get_replies(msg('!start'))
      # We need to mess with Cinch::User.new because cinch-test is messing with us.
      # (creating users who are eql? but whose hash are not the same)
      expect(Cinch::User).to receive(:new).with(player1, anything).and_return(first_message.user)
      replies = get_replies_text(msg('!join', nick: player1))
      # Empty because of the no reply on join in the same channel rule
      expect(replies).to be_empty
    end

    it 'disallows overflow' do
      players.take(3).each { |p| join(msg('!join', nick: p)) }
      m = msg('!join', nick: player4)
      expect(m.channel).to receive(:has_user?).with(m.user).and_return(true)
      replies = get_replies_text(m)
      expect(replies).to be == [
        "#{player4}: Game is already at 3 players, the maximum supported for Example Game."
      ]
    end
  end

  describe '!leave' do
    it 'no-ops if player is not in game' do
      replies = get_replies(msg('!leave', nick: player1))
      expect(replies).to be_empty
    end

    it 'leaves game' do
      join(msg('!join', nick: player1))
      expect(plugin).to receive(:Channel).with(channel1).and_return(chan)
      get_replies(msg('!leave', nick: player1))
      expect(chan.messages).to be == ["#{player1} has left the game (0/3)"]
    end

    it 'disallows leaving started game' do
      join(msg('!join', nick: player1))
      join(msg('!join', nick: player2))
      get_replies(msg('!start'))
      replies = get_replies_text(msg('!leave', nick: player1))
      expect(replies).to be == ["#{player1}: You cannot leave a game in progress."]
    end
  end

  describe '!start' do
    it 'disallows bystander start' do
      join(msg('!join', nick: player1))
      join(msg('!join', nick: player2))
      replies = get_replies_text(msg('!start', nick: player3))
      expect(replies).to be == ["#{player3}: You are not in the game."]
    end

    it 'allows start' do
      join(msg('!join', nick: player1))
      join(msg('!join', nick: player2))
      get_replies_text(msg('!start'))
      # What to test here? This just tests that we have no crash. !status and !who are testing a bit.
    end

    it 'disallows start with too few players' do
      join(msg('!join', nick: player1))
      get_replies(msg('!start'))
      replies = get_replies_text(msg('!start', nick: player1))
      expect(replies).to be == ["#{player1}: Need at least 2 to start a game of Example Game."]
    end
  end

  describe '!who' do
    it 'says no players in game' do
      replies = get_replies_text(msg('!who', nick: player1))
      expect(replies).to be == ['No one has joined the game yet.']
    end

    it 'names players in unstarted game' do
      join(msg('!join', nick: player1))
      replies = get_replies_text(msg('!who', nick: player1)).map { |t| t.gsub(/\W/, '') }
      expect(replies).to be == [player1]
    end

    it 'names players in started game' do
      join(msg('!join', nick: player1))
      join(msg('!join', nick: player2))
      get_replies(msg('!start'))
      replies = get_replies_text(msg('!who', nick: player1)).map { |t| t.gsub(/[^a-z0-9 ]/, '') }
      expect(replies).to be == ["#{player1} #{player2}"]
    end
  end

  describe '!status' do
    it 'says no players in game' do
      replies = get_replies_text(msg('!status', nick: player1))
      expect(replies).to be == ['No game of Example Game in progress. Join and start one!']
    end

    it 'names players in unstarted game' do
      join(msg('!join', nick: player1))
      replies = get_replies_text(msg('!status', nick: player1))
      expect(replies).to be == ["A game of Example Game is forming. 1 players have joined: #{player1}"]
    end

    it 'names players in started game' do
      join(msg('!join', nick: player1))
      join(msg('!join', nick: player2))
      get_replies(msg('!start'))
      replies = get_replies_text(msg('!status', nick: player1))
      expect(replies).to be == ["Game started with players test1, test2"]
    end
  end
end