require "rubygems"
require "bundler/setup"

require 'sinatra/base'
require 'erb'
# require 'resque'
# require 'resque/version'
require 'time'

require 'sidekiq'

class SomeWorker

  attr_reader :to_s
  attr_reader :job

  def initialize package
    @to_s = package[:id]
    @job = package[:payload]  
  end

  def state
  end

  def idle?
    false
  end
end

module Resque
  extend self

  def redis
    @sidekiq_redis ||= Sidekiq::RedisConnection.create({ use_pool: false })

    #If there is no namespace defined, should this be here but just be null?
    def @sidekiq_redis.namespace
      nil
    end
    @sidekiq_redis
  end

  def queues
    redis.smembers("resque:queues")
  end  

  def size queue
    redis.llen("resque:queue:#{queue}")
  end

  def workers
    redis.smembers('resque:workers').map{
      |worker| 
      #Hack, this should be a SomeWorker class, analagous to the Worker class in Resque
      def worker.state; "Unknown"; end
      def worker.processing; {} ; end

      worker
    }
  end

  def working
    working_workers = workers.map do |worker|
      entry = redis.get("resque:worker:#{worker}")
      next unless entry
      SomeWorker.new({
        :id => "resque:worker:#{worker}",
        :payload => MultiJson.decode(entry)
        })
    end.compact
  end

  def list_range(key, start = 0, count = 1)
    if count == 1
      decode redis.lindex(key, start)
    else
      Array(redis.lrange(key, start, start+count-1)).map do |item|
        decode item
      end
    end
  end

  def decode payload
    MultiJson.decode payload
  end

  def peek(queue, start = 0, count = 1)
    list_range("resque:queue:#{queue}", start, count)
  end

  def redis_id
    # support 1.x versions of redis-rb
    if redis.respond_to?(:server)
      redis.server
    elsif redis.respond_to?(:nodes) # distributed
      redis.nodes.map { |n| n.id }.join(', ')
    else
      redis.client.id
    end
  end

  module Version
    123
  end

  class Failure
    def self.count 
      0
    end
  end

end

  module Resque
  class Server < Sinatra::Base
    dir = File.dirname(File.expand_path(__FILE__))

    set :views,  "#{dir}/views"
    set :public, "#{dir}/public"
    set :static, true

    helpers do
      include Rack::Utils
      alias_method :h, :escape_html

      def current_section
        url_path request.path_info.sub('/','').split('/')[0].downcase
      end

      def current_page
        url_path request.path_info.sub('/','')
      end

      def url_path(*path_parts)
        [ path_prefix, path_parts ].join("/").squeeze('/')
      end
      alias_method :u, :url_path

      def path_prefix
        request.env['SCRIPT_NAME']
      end

      def class_if_current(path = '')
        'class="current"' if current_page[0, path.size] == path
      end

      def tab(name)
        dname = name.to_s.downcase
        path = url_path(dname)
        "<li #{class_if_current(path)}><a href='#{path}'>#{name}</a></li>"
      end

      def tabs
        Resque::Server.tabs
      end

      def redis_get_size(key)
        case redis.type(key)
        when 'none'
          []
        when 'list'
          redis.llen(key)
        when 'set'
          redis.scard(key)
        when 'string'
          redis.get(key).length
        when 'zset'
          redis.zcard(key)
        end
      end

      def redis_get_value_as_array(key, start=0)
        case redis.type(key)
        when 'none'
          []
        when 'list'
          redis.lrange(key, start, start + 20)
        when 'set'
          redis.smembers(key)[start..(start + 20)]
        when 'string'
          [redis.get(key)]
        when 'zset'
          redis.zrange(key, start, start + 20)
        end
      end

      def show_args(args)
        Array(args).map { |a| a.inspect }.join("\n")
      end

      def worker_hosts
        @worker_hosts ||= worker_hosts!
      end

      def worker_hosts!
        hosts = Hash.new { [] }

        Resque.workers.each do |worker|
          host, _ = worker.to_s.split(':')
          hosts[host] += [worker.to_s]
        end

        hosts
      end

      def partial?
        @partial
      end

      def partial(template, local_vars = {})
        @partial = true
        erb(template.to_sym, {:layout => false}, local_vars)
      ensure
        @partial = false
      end

      def poll
        if @polling
          text = "Last Updated: #{Time.now.strftime("%H:%M:%S")}"
        else
          text = "<a href='#{u(request.path_info)}.poll' rel='poll'>Live Poll</a>"
        end
        "<p class='poll'>#{text}</p>"
      end


      

    end

    def show(page, layout = true)
      response["Cache-Control"] = "max-age=0, private, must-revalidate"
      begin
        erb page.to_sym, {:layout => layout}, :resque => Resque
      rescue Errno::ECONNREFUSED
        erb :error, {:layout => false}, :error => "Can't connect to Redis! (#{redis_id})"
      end
    end

    def show_for_polling(page)
      content_type "text/html"
      @polling = true
      show(page.to_sym, false).gsub(/\s{1,}/, ' ')
    end

    # to make things easier on ourselves
    get "/?" do
      redirect url_path(:overview)
    end

    %w( overview workers ).each do |page|
      get "/#{page}.poll" do
        show_for_polling(page)
      end

      get "/#{page}/:id.poll" do
        show_for_polling(page)
      end
    end

    %w( overview queues working workers key ).each do |page|
      get "/#{page}" do
        show page
      end

      get "/#{page}/:id" do
        show page
      end
    end

    post "/queues/:id/remove" do
      Resque.remove_queue(params[:id])
      redirect u('queues')
    end

    get "/failed" do
      if Resque::Failure.url
        redirect Resque::Failure.url
      else
        show :failed
      end
    end

    post "/failed/clear" do
      Resque::Failure.clear
      redirect u('failed')
    end

    post "/failed/requeue/all" do
      Resque::Failure.count.times do |num|
        Resque::Failure.requeue(num)
      end
      redirect u('failed')
    end

    get "/failed/requeue/:index" do
      Resque::Failure.requeue(params[:index])
      if request.xhr?
        return Resque::Failure.all(params[:index])['retried_at']
      else
        redirect u('failed')
      end
    end

    get "/failed/remove/:index" do
      Resque::Failure.remove(params[:index])
      redirect u('failed')
    end

    get "/stats" do
      redirect url_path("/stats/resque")
    end

    get "/stats/:id" do
      show :stats
    end

    get "/stats/keys/:key" do
      show :stats
    end

    get "/stats.txt" do
      info = Resque.info

      stats = []
      stats << "resque.pending=#{info[:pending]}"
      stats << "resque.processed+=#{info[:processed]}"
      stats << "resque.failed+=#{info[:failed]}"
      stats << "resque.workers=#{info[:workers]}"
      stats << "resque.working=#{info[:working]}"

      Resque.queues.each do |queue|
        stats << "queues.#{queue}=#{Resque.size(queue)}"
      end

      content_type 'text/html'
      stats.join "\n"
    end

    def resque
      Resque
    end

    def self.tabs
      @tabs ||= ["Overview", "Working", "Failed", "Queues", "Workers", "Stats"]
    end
  end
end
