#!/usr/bin/env ruby

class PivotalTracker
  include HTTParty
  base_uri ENV["PIVOTAL_TRACKER_URL"] || "https://www.pivotaltracker.com/services/v5"
  #debug_output $stdout

  DEFAULT_QUERY_OPTS = {:format => "json"}

  def initialize(tracker_token, opts={})
    @verbose        = opts[:verbose].nil?  ? false                : opts[:verbose]
    @project_filter = opts[:projects].nil? ? []                   : opts[:projects]
    @tracker_token  = tracker_token
  end

  def headers
    {:headers => {"X-TrackerToken" => @tracker_token}}
  end

  def history(project_id, query_opts={})
    options = {
      :query => {
        :end_date     => Time.now.strftime("%Y-%m-%d"),
        :start_date   => Time.now.strftime("%Y-%m-%d")
      }.merge(DEFAULT_QUERY_OPTS).merge(query_opts)
    }.merge(headers)

    response = self.class.get("/projects/#{project_id}/history/days", options)
    data   = JSON.parse(response.body)["data"]
    header = JSON.parse(response.body)["header"]

    data.inject([]) {|res, val| res << Hash[*header.zip(val).flatten]}
  end

  def projects(query_opts={})
    options = {
      :query => {}.merge(DEFAULT_QUERY_OPTS).merge(query_opts)
    }.merge(headers)

    self.class.get("/projects", options)
  end

  def project_ids
    self.projects.inject({}) {|res, project| res.merge(project["id"] => project["name"])}
  end
end