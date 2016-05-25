#!/usr/bin/env ruby

class Datatarget
  attr_reader :client, :env_token, :options

  def initialize(env_token, opts={})
    @env_token = env_token
    @options   = {
      :verbose => false,
      :enabled => true,
      :submit_time => Time.now.utc.strftime("%Y-%m-%d %H:%M:%S")
    }.merge(opts)

    init_client
  end

  def init_client
  end

  def verbose?
    options[:verbose]
  end

  def enabled?
    options[:enabled]
  end
end

class DataboxTarget < Datatarget
  def init_client
    puts "env_token: #{ENV[env_token]}" if verbose?
    Databox.configure do |c| 
      c.push_token = ENV[env_token]
    end

    @client = Databox::Client.new
  end

  def publish(project_key, metrics, opts={})
    additional_attributes = opts[:attributes] || {}
    attributes = { project: project_key }.merge(additional_attributes)

    if enabled?
      metrics.each_pair { |metric, value| puts "client.push(key: #{metric.to_s}, value: #{value}, date: #{options[:submit_time]}, attributes: #{attributes})" } if verbose?
      metrics.each_pair { |metric, value| client.push(key: metric.to_s, value: value, date: options[:submit_time], attributes: attributes) }
    end
  end
end

class DatadogTarget < Datatarget
  def init_client
    @client = Dogapi::Client.new(ENV[env_token])
  end

  def publish(collection, project_key, metrics)
    if enabled?
      metrics.each_pair { |metric, value| puts "client.emit_point \"#{collection.to_s}.#{metric.to_s}\", #{value}, :tags => [\"project:#{project_key}\"]" } if verbose?
      metrics.each_pair { |metric, value| client.emit_point "#{collection.to_s}.#{metric.to_s}", value, :tags => ["project:#{project_key}"] }
    end
  end
end

class KeenTarget < Datatarget
  def publish(collection, data)
    if enabled?
      puts "keen_data: #{keen_data.inspect}\nkeen_data.class -> #{keen_data.class}" if verbose?
      ::Keen.publish_batch(collection => keen_data)
    end
  end
end