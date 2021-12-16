require 'httparty'
require 'open-uri'
require 'json'
require 'pry-byebug'

namespace :redmine do
  class Connector
    # @example Connecting with Username and Password and fetching Issues
    # Connector.new({:url=> '...', :key=> '...'})
    # Please make sure that the url ends with a '/'
    def initialize(options)
      @url = options[:url]
      @key = options[:key]

      raise 'Invalid connector configuration!' if @url.nil? || @key.nil?
    end

    def select(uri, type, *attributes)
      # alexm
      # response = HTTParty.get(@url + "%s.json" % uri,
      response = HTTParty.get(@url + '%s.json?limit=1000' % uri,
                              headers: { 'X-Redmine-API-Key' => @key, "Content-Type": 'application/json' })

      raise "[Error: %s] Can't reach the API!" % response.code if response.code != 200

      filter JSON.parse(response.body, symbolize_names: true), type, *attributes
    end

    def select_users(uri, type, *attributes)
      # response = HTTParty.get(@url + "%s.json" % uri,
      response = HTTParty.get(@url + '%s.json?limit=1000&status=' % uri,
                              headers: { 'X-Redmine-API-Key' => @key, "Content-Type": 'application/json' })

      raise "[Error: %s] Can't reach the API!" % response.code if response.code != 200

      filter JSON.parse(response.body, symbolize_names: true), type, *attributes
    end

    def insert(uri, values)
      response = HTTParty.post(@url + '%s.json' % uri, query: values,
                                                       headers: { 'X-Redmine-API-Key' => @key, 'Content-Type' => 'application/json' })

      raise "[Error: %s] Can't reach the API!" % response.code if response.code != 201

      JSON.parse(response.body, symbolize_names: true)
    end

    def update(uri, values)
      response = HTTParty.put(@url + '%s.json' % uri, query: values,
                                                      headers: { 'X-Redmine-API-Key' => @key, 'Content-Type' => 'application/json' })

      if (response.code != 200) && (response.code != 204)
        p response.code
        p response.body

        raise "[Error: %s] Can't reach the API!" % response.code
      end
    end

    def filter(data, type, *attributes)
      raise 'Invalid data!' unless data.is_a?(Hash)

      type = type.to_sym
      raise 'Invalid response!' unless data.has_key? type

      if data[type].is_a?(Array)
        return data[type].map { |u| u.select { |k, _v| attributes.empty? || attributes.include?(k) } }
      end

      data[type].select { |k, _v| attributes.empty? || attributes.include?(k) } if data[type].is_a?(Hash)
    end

    def statuses
      select '/issue_statuses', :issue_statuses, :id, :name
    end

    def trackers
      select '/trackers', :trackers, :id, :name
    end

    def priorities
      select '/enumerations/issue_priorities', :issue_priorities, :id, :name
    end

    def users
      # return select "/users", :users,:id, :mail, :login
      select_users '/users', :users, :id, :mail, :login, :status
    end

    def projects
      select '/projects', :projects, :id, :name, :identifier
    end

    def roles
      select '/roles', :roles, :id, :name
    end

    def custom_fields
      select '/custom_fields', :custom_fields, :id, :name
    end

    def memberships(id)
      (select '/projects/%s/memberships' % id, :memberships, :user).map { |v| v[:user][:id] }
    end

    def create_user(data)
      filter insert('/users', { user: data }), :user, :id, :mail
    end

    def update_user(id, data)
      update('/users/%s' % id, { user: data })
    end

    def create_project(data)
      filter insert('/projects', { project: { name: data[:name], identifier: data[:key].downcase, description: data[:description], is_public: 'false' } }),
             :project, :id, :name, :identifier
    end

    def create_subproject(data, project_parent_id)
      filter insert('/projects', { project: { name: data[:name], identifier: data[:key].downcase, description: data[:description], is_public: 'false', parent_id: project_parent_id } }),
             :project, :id, :name, :identifier
    end

    def create_issue(data)
      filter insert('/issues', { issue: data }), :issue, :id
    end

    def create_membership(project, data)
      filter insert('/projects/%s/memberships' % project, { membership: data }), :membership, :id
    end

    def update_issue(id, data)
      update('/issues/%s' % id, { issue: data })
    end

    def create_issue_link(id, data)
      insert('/issues/%s/relations' % id, { relation: data })
    end

    def create_project_version(id, data)
      filter insert('/projects/%s/versions' % id, { version: data }), :version, :id
    end

    private :select, :insert, :filter
  end
end
