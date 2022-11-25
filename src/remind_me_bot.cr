require "xml"

require "mastodon"
require "sqlite3"
require "tasker"
require "dotenv"

Dotenv.load?

class RemindMeBot
  @db : DB::Database

  def initialize
    access_token = ENV["ACCESS_TOKEN"]?
    @client = access_token ? Mastodon::REST::Client.new(url: ENV["INSTANCE_URL"], access_token: access_token) : Mastodon::REST::Client.new(url: ENV["INSTANCE_URL"])
    @streaming_client = access_token ? Mastodon::Streaming::Client.new(url: ENV["INSTANCE_URL"], access_token: access_token) : Mastodon::Streaming::Client.new(url: ENV["INSTANCE_URL"])
    @db = DB.open("sqlite3://./bot.db")

    run_auth_flow unless access_token
    setup_database
    create_task
  end

  def run_auth_flow
    puts "Authentication required! Please visit the following URL and authorize the application:"
    puts @client.authorize_uri(client_id: ENV["CLIENT_ID"], scopes: "read write follow")
    puts
    puts "Paste the authorization code here:"
    code = gets.try &.chomp
    token = @client.get_access_token_using_authorization_code(client_id: ENV["CLIENT_ID"], client_secret: ENV["CLIENT_SECRET"], scopes: "read write follow", code: code)
    puts
    puts "To skip this process next time, add the following line to your .env file:"
    puts "ACCESS_TOKEN=#{token.access_token}"
    @client.authenticate(token)
    @streaming_client.authenticate(token)
  end

  def run
    @streaming_client.hashtag("remindme") do |status|
      if status.is_a?(Mastodon::Entities::Status) && (reply_to_id = status.in_reply_to_id)
        html = XML.parse_html(status.content)
        text = html.inner_text
        if hashtag_index = text.index("#remindme")
          text = text[hashtag_index..]
          time = parse_remind_me(text)
          reply_status = @client.status(reply_to_id)
          @db.exec("INSERT INTO reminders (time, status_uri, username) VALUES (?, ?, ?)", time, reply_status.uri, status.account.username)
        end
      end
    end
  end

  def parse_remind_me(content)
    if matches = content.match(/(?:in )?(\d+) (minutes?|hours?|days?|weeks?|months?|years?)/i)
      time = matches[1].to_i
      unit = matches[2]
      case unit
      when "minute", "minutes"
        time.minutes.from_now
      when "hour", "hours"
        time.hours.from_now
      when "day", "days"
        time.days.from_now
      when "week", "weeks"
        time.weeks.from_now
      when "month", "months"
        time.months.from_now
      when "year", "years"
        time.years.from_now
      end
    end
  end

  def setup_database
    @db.exec <<-SQL
      CREATE TABLE IF NOT EXISTS reminders (
        id INTEGER PRIMARY KEY,
        time TIMESTAMP,
        status_uri TEXT,
        username TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
    SQL
  end

  def create_task
    Tasker.every(30.seconds) do
      @db.query("SELECT * FROM reminders WHERE time < ?", Time.utc) do |rs|
        reminders = Reminder.from_rs(rs)
        reminders.each do |reminder|
          @client.create_status(
            "@#{reminder.username} at #{reminder.created_at.to_s("%m/%d/%y %M:%H")} you asked me to remind you of this: #{reminder.status_uri}",
            visibility: "direct"
          )
          @db.exec("DELETE FROM reminders WHERE id = ?", reminder.id)
        end
      end
    end
  end

  class Reminder
    include DB::Serializable

    property id : Int32
    property time : Time
    property status_uri : String
    property username : String
    property created_at : Time
  end
end

RemindMeBot.new.run
