# encoding: utf-8

class FnordMetric::App < Sinatra::Base

  @@sessions = Hash.new
  @@public_files = {
    "fnordmetric.css" => "text/css",
    "fnordmetric.js" => "application/x-javascript",
    "fnordmetric.ui.js" => "application/x-javascript",
    "fnordmetric.util.js" => "application/x-javascript",
    "fnordmetric.dashboard_view.js" => "application/x-javascript",
    "fnordmetric.gauge_view.js" => "application/x-javascript",
    "fnordmetric.overview_view.js" => "application/x-javascript",
    "fnordmetric.session_view.js" => "application/x-javascript",
    "fnordmetric.timeline_widget.js" => "application/x-javascript",
    "fnordmetric.numbers_widget.js" => "application/x-javascript",
    "fnordmetric.realtime_value_widget.js" => "application/x-javascript",
    "fnordmetric.bars_widget.js" => "application/x-javascript",
    "fnordmetric.toplist_widget.js" => "application/x-javascript",
    "fnordmetric.pie_widget.js" => "application/x-javascript",
    "fnordmetric.html_widget.js" => "application/x-javascript",
    "vendor/d3.v2.js" => "application/x-javascript",
    "vendor/jquery-1.6.1.min.js" => "application/x-javascript",
    "vendor/highcharts.js" => "application/x-javascript",
    "vendor/raphael.min.js" => "application/x-javascript",
    "vendor/raphael.util.js" => "application/x-javascript",
    "img/list.png" => "image/png",
    "img/list_active.png" => "image/png",
    "img/list_hover.png" => "image/png",
    "img/picto_gauge.png" => "image/png",
    "img/head.png" => "image/png",
    "img/navbar.png" => "image/png",
    "img/navbar_btn.png" => "image/png"
  }

  if RUBY_VERSION =~ /1.9.\d/
    Encoding.default_external = Encoding::UTF_8
  end

  enable :session

  set :haml, :format => :html5
  set :views, ::File.expand_path('../../../../web/haml', __FILE__)

  def initialize(opts)
    @namespaces = FnordMetric.namespaces
    @redis = Redis.connect(:url => opts[:redis_url])
    @opts = opts
    super(nil)
  end

  helpers do
    include Rack::Utils
    alias_method :h, :escape_html

    def path_prefix
      request.env["SCRIPT_NAME"]
    end

    def namespaces
      @namespaces
    end

    def current_namespace
      @namespaces[@namespaces.keys.detect{ |k|
        k.to_s == params[:namespace]
      }.try(:intern)]
    end

  end

  if ENV['RACK_ENV'] == "test"
    set :raise_errors, true
  end

  get '/' do
    redirect "#{path_prefix}/#{@namespaces.keys.first}"
  end

  get '/:namespace' do
    pass unless current_namespace
    haml :app
  end

  get '/favicon.ico' do
    ""
  end

  get '/:namespace/gauge/:name' do

    gauge = if params[:name].include?("++")
      parts = params[:name].split("++")
      current_namespace.gauges[parts.first.to_sym].fetch_gauge(parts.last, params[:tick].to_i)
    else
      current_namespace.gauges[params[:name].to_sym]
    end

    if !gauge
      status 404
      return ""
    end

    data = if gauge.three_dimensional?
      _t = (params[:at] || Time.now).to_i
      { :count => gauge.field_values_total(_t), :values => gauge.field_values_at(_t) }
    elsif params[:at] && params[:at] =~ /^[0-9]+$/
      { (_t = gauge.tick_at(params[:at].to_i)) => gauge.value_at(_t) }
    elsif params[:at] && params[:at] =~ /^([0-9]+)-([0-9]+)$/
      _range = params[:at].split("-").map(&:to_i)
      _values = gauge.values_in(_range.first.._range.last)
      params[:sum] ? { :sum => _values.values.compact.map(&:to_i).sum } : _values
    else
      { (_t = gauge.tick_at(Time.now.to_i-gauge.tick)) => gauge.value_at(_t) }
    end

    data.to_json
  end

  get '/:namespace/sessions' do

    sessions = current_namespace.sessions(:all, :limit => 100).map do |session|
      session.fetch_data!
      session.to_json
    end

    { :sessions => sessions }.to_json
  end

  get '/:namespace/events' do

    events = if params[:type]
      current_namespace.events(:by_type, :type => params[:type])
    elsif params[:session_key]
      current_namespace.events(:by_session_key, :session_key => params[:session_key])
    else 
      find_opts = { :limit => 100 }
      find_opts.merge!(:since => params[:since].to_i+1) if params[:since]
      current_namespace.events(:all, find_opts)
    end

    { :events => events.map(&:to_json) }.to_json
  end

  get '/:namespace/event_types' do
    types_key = current_namespace.key_prefix("type-")
    keys = @redis.keys("#{types_key}*").map{ |k| k.gsub(types_key,'') }

    { :types => keys }.to_json
  end

  get '/:namespace/dashboard/:dashboard' do
    dashboard = current_namespace.dashboards.fetch(params[:dashboard])

    dashboard.to_json
  end

  post '/events' do
    halt 400, 'please specify the event_type (_type)' unless params["_type"]
    track_event((8**32).to_s(36), parse_params(params))
  end

  @@public_files.each do |public_file, public_file_type|
    get "/#{public_file}" do
      content_type(public_file_type)
      ::File.open(::File.expand_path("../../../../web/#{public_file}", __FILE__)).read
    end
  end
private

  def parse_params(hash)
    hash.tap do |h|
      h.keys.each{ |k| h[k] = parse_param(h[k]) }
    end
  end

  def parse_param(object)
    return object unless object.is_a?(String)
    return object.to_f if object.match(/^[0-9]+[,\.][0-9]+$/)
    return object.to_i if object.match(/^[0-9]+$/)
    object
  end

  def track_event(event_id, event_data)
    @redis.hincrby "#{@opts[:redis_prefix]}-stats",             "events_received", 1
    @redis.set     "#{@opts[:redis_prefix]}-event-#{event_id}", event_data.to_json
    @redis.lpush   "#{@opts[:redis_prefix]}-queue",             event_id
    @redis.expire  "#{@opts[:redis_prefix]}-event-#{event_id}", @opts[:event_queue_ttl]
  end

end

