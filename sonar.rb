#!/usr/bin/env ruby

class Sonar
  attr_reader :verbose, :project_filter, :to_time, :from_time

  include HTTParty
  base_uri ENV["SONAR_URL"]
  #debug_output $stdout

  def initialize(opts={})
    @verbose        = opts[:verbose].nil?  ? false                : opts[:verbose]
    @project_filter = opts[:projects].nil? ? []                   : opts[:projects]
    @to_time        = opts[:to_time].nil?  ? Time.now.utc.iso8601 : opts[:to_time]
    @from_time      = opts[:from_time]
  end

  DEFAULT_QUERY_OPTS = {:format => "json"}
  ISSUE_SEVERITIES   = ["blocker", "critical", "major", "minor", "info"]

  def self.last_cell_value(http_response)
    #puts "Debug: #{http_response.body}" if options[:verbose]
    JSON.parse(http_response.body).last["cells"].last.andand["v"]
  end

  def metrics(metrics,resource,query_opts={})
    options = {
      :query => {
        :metrics      => metrics,
        :resource     => resource,
        :toDateTime   => to_time,
        :fromDateTime => from_time
      }.merge(DEFAULT_QUERY_OPTS).merge(query_opts).reject {|k,v| v.nil?}
    }

    self.class.get("/api/timemachine", options)
  end

  def resources(query_opts={})
    options = DEFAULT_QUERY_OPTS.merge(query_opts)

    self.class.get("/api/resources/index", options)
  end

  def projects
    project_keys = JSON.parse(resources(:qualifiers => "TRK").body).collect{|r| r["key"]}
    project_filter.empty? ? project_keys : project_keys & project_filter
  end

  def project_issues(project_key)
    ISSUE_SEVERITIES.inject({}) do |res, sev|
      data = ["#{sev}_violations", "new_#{sev}_violations"].inject({}) do |ires, metric|
        val = Sonar::last_cell_value(metrics(metric, project_key)).andand.first
        val.nil? ? ires : ires.merge(metric.to_sym => val)
      end

      res.merge(data)
    end
  end

  def project_complexity(project_key)
    ["complexity", "class_complexity", "file_complexity", "function_complexity"].inject({}) do |res, metric|
      val = Sonar::last_cell_value(metrics(metric, project_key)).andand.first
      val.nil? ? res : res.merge(metric.to_sym => val)
    end
  end

  def project_duplications(project_key)
    ["duplicated_blocks", "duplicated_files", "duplicated_lines", "duplicated_lines_density"].inject({}) do |res, metric|
      val = Sonar::last_cell_value(metrics(metric, project_key)).andand.first
      val.nil? ? res : res.merge(metric.to_sym => val)
    end
  end

  def quality_gate_map
    {
      "ERROR" => -2,
      "WARN"  => -1,
      "OK"    => 0
    }
  end

  def project_quality_gate(project_key)
    string_val = Sonar::last_cell_value(metrics("alert_status", project_key)).andand.first
    string_val.nil? ? {} : {:quality_gate_status => self.quality_gate_map[string_val]}
  end

  def project_tests(project_key)
    ["coverage", "new_coverage"].inject({}) do |res, metric|
      val = Sonar::last_cell_value(metrics(metric, project_key)).andand.first
      val.nil? ? res : res.merge(metric.to_sym => val)
    end
  end

  def project_tech_debt(project_key)
    ["sqale_index", "sqale_debt_ratio"].inject({}) do |res, metric|
      val = Sonar::last_cell_value(metrics(metric, project_key)).andand.first
      val.nil? ? res : res.merge(metric.to_sym => val)
    end
  end
end