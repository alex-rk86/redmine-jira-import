require 'nokogiri'
require 'digest'
require 'base64'
require 'fileutils'
require 'active_record'
require 'pry-byebug'
require 'remove_emoji'
require 'colorize'

require './lib/builder'
require './lib/storage'

namespace :jira do
  # Struc with hash passed on constructor
  class ExtendedStruct < Struct
    def initialize(params = {})
      params.each do |k, v|
        send("#{k}=", v) if members.include?(k.to_sym)
      end
    end
  end

  # Main Jira import class
  class Import
    JIRA_ISSUE_KEY = '%issue key%'.freeze
    JIRA_LABEL_KEY = '%label%'.freeze

    JiraProject = ExtendedStruct.new(:name, :lead, :description, :key)
    JiraProjectVersion = ExtendedStruct.new(:project, :name, :description)
    JiraIssue = ExtendedStruct.new(:key, :project, :creator, :assignee, :type, :summary, :description,
                                   :priority, :status, :created, :updated, :security, :timeoriginalestimate,
                                   :duedate)
    JiraIssueLink = ExtendedStruct.new(:linktype, :source, :destination)
    JiraComment = ExtendedStruct.new(:issue, :author, :body, :created, :rolelevel)
    JiraWorklog = ExtendedStruct.new(:issue, :author, :body, :startdate, :timeworked)
    JiraAttache = ExtendedStruct.new(:issue, :author, :mimetype, :filename, :created, :filesize)
    JiraHistory = ExtendedStruct.new(:group, :fieldtype, :field, :newvalue, :oldvalue, :newstring, :oldstring)
    JiraHistoryGroup = ExtendedStruct.new(:issue, :author, :created)
    JiraNodeAssociation = ExtendedStruct.new(:sourceNodeId, :sourceNodeEntity, :sinkNodeId, :sinkNodeEntity,
                                             :associationType)
    JiraCustomFieldValue = ExtendedStruct.new(:issue, :customfield, :stringvalue)
    JiraLabel = ExtendedStruct.new(:issue, :label)

    def initialize
      @app_config = YAML.load_file('./config/config.yml')
      puts 'Jira2Redmine importer by alex@rk86.com'.green
      puts '---'.green
      puts 'Using configuration:'
      puts format('%s', @app_config).cyan

      @jirafiles = File.join(@app_config['JIRA_ATTACHMENTS_DIR'])
      raise format('Invalid Jira attachments directory: %s', @jirafiles) unless Dir.exist? @jirafiles

      @outputsql = @app_config['SQL_OUTPUT_FILE']
      raise format('Invalid output SQL directory: %s', @outputsql) unless Dir.exist? File.dirname(@outputsql)

      @outputfiles = @app_config['ATTACHMENTS_OUTPUT_DIR']
      raise format('Invalid output attachments output directory: %s', @ouputfiles) unless Dir.exist? @outputfiles

      @sqlitefile = @app_config['SQLITE_FILE']
      raise format('Invalid sqlite file directory: %s', @sqlitefile) unless Dir.exist? File.dirname(@sqlitefile)

      @start_time = Time.now

      if @app_config['RUNNING_MODE'].between?(0, 4)
        puts format('Processing Jira project "%s", mode: "%s"...', @app_config['PROJECT_TO_IMPORT'], @app_config['RUNNING_MODE']).green
        puts 'Loading Jira xml file...'
        @jiraxml = Nokogiri::XML(File.new(@app_config['JIRA_XML_FILE'], 'r:utf-8'), nil, 'utf-8') { |c| c.noblanks }
        raise 'Jira XML is empty!' if @jiraxml.root.children.count < 1
      end

      @connector = Connector.new({ url: @app_config['REDMINE_URL'], key: @app_config['REDMINE_KEY'] })
      @builder = Builder.new(@outputsql)
      @storage = Storage.new(@sqlitefile)
    end

    def migrate
      if @app_config['RUNNING_MODE'].between?(0, 4)
        puts 'Loading Jira statuses...'
        load_jira_statuses
        puts 'Loading Jira types...'
        load_jira_types
        puts 'Loading Jira priorities...'
        load_jira_priorities
        puts 'Loading Jira custom fields...'
        load_jira_customfields
        puts 'Prepare roles...'
        prepare_roles

        puts 'Prepare statuses...'
        raise '[Error] Sorry! Undefined statuses found!' if prepare_statuses.positive?

        puts 'Prepare trackers...'
        raise '[Error] Sorry! Undefined trackers found!' if prepare_trackers.positive?

        puts 'Prepare priorities...'
        raise '[Error] Sorry! Undefined priorities found!' if prepare_priorities.positive?

        puts 'Prepare custom fields...'
        raise '[Error] Sorry! Undefined custom fields found!' if prepare_customfields.positive?

        if @app_config['RUNNING_MODE'].between?(1, 4)
          puts 'Loading Jira users...'
          load_jira_users
          load_jira_user_aliases
          puts 'Migrate users...'
          migrate_users
        end

        if @app_config['RUNNING_MODE'] == 4
          puts 'Loading Jira projects...'
          load_jira_projects
          puts 'Loading Jira versions...'
          load_jira_project_versions
          puts 'Loading Jira issues...'
          load_jira_issues
          puts 'Loading Jira issues links...'
          load_jira_issue_links
          puts 'Loading Jira node associations...'
          load_jira_node_associations
          puts 'Loading Jira comments...'
          load_jira_comments
          puts 'Loading Jira history...'
          load_jira_history
          puts 'Loading Jira attachments...'
          load_jira_attaches
          puts 'Loading Jira worklogs...'
          load_jira_worklogs
          puts 'Loading Jira custom field values...'
          load_jira_customfield_values
          puts 'Loading Jira labels...'
          load_jira_labels
          puts 'Migrate projects...'
          migrate_projects
          puts 'Migrate issues...'
          migrate_issues
        end
      end
      if @app_config['RUNNING_MODE'] == 5
        puts format('Cleaning internal storage for %s', @app_config['PROJECT_TO_IMPORT'])
        @storage.cleanup_project(@app_config['PROJECT_TO_IMPORT'].downcase)
      end
      if @app_config['RUNNING_MODE'] == 6
        puts format('Updating cross project relations...')
        update_cross_project_relations
      end
      puts format('Done, it took %s seconds', (Time.now - @start_time).to_i).green
    end

    def prepare_roles
      @default_role = @connector.roles.select do |v|
        v[:name].downcase == @app_config['DEFAULT_USER_ROLE']
      end.first
      raise 'No default role found!' if @default_role.nil?
    end

    def prepare_statuses
      @statuses_binding = {}
      redmine_statuses = @connector.statuses
      count = 0
      @statuses.each do |id, name|
        puts ' - status found: %s' % name
        search = name.downcase
        search = @app_config['STATUS_ALIASES'][search] if @app_config['STATUS_ALIASES'].key?(search)
        redmine_status = redmine_statuses.select { |v| v[:name].downcase == search }.first
        if !redmine_status.nil?
          puts ' - status assigned: %s!' % redmine_status[:name]
          @statuses_binding[id] = redmine_status[:id]
        else
          puts ' - undefined status: %s' % name
          count += 1
        end
      end
      count
    end

    def prepare_trackers
      @trackers_binding = {}
      redmine_trackers = @connector.trackers
      count = 0
      @types.each do |id, name|
        puts ' - tracker found: %s' % name
        search = name.downcase
        search = @app_config['TRACKER_ALIASES'][search] if @app_config['TRACKER_ALIASES'].key?(search)
        redmine_tracker = redmine_trackers.select { |v| v[:name].downcase == search }.first
        if !redmine_tracker.nil?
          puts ' - tracker assigned: %s!' % redmine_tracker[:name]
          @trackers_binding[id] = redmine_tracker[:id]
        else
          puts ' - undefined tracker: %s' % name
          count += 1
        end
      end
      count
    end

    def prepare_priorities
      @priorities_binding = {}
      redmine_priorities = @connector.priorities
      count = 0
      @priorities.each do |id, name|
        puts ' - priority found: %s' % name
        search = name.downcase
        search = @app_config['PRIORITY_ALIASES'][search] if @app_config['PRIORITY_ALIASES'].key?(search)
        redmine_priority = redmine_priorities.select { |v| v[:name].downcase == search }.first
        if !redmine_priority.nil?
          puts ' - priority assigned: %s!' % redmine_priority[:name]
          @priorities_binding[id] = redmine_priority[:id]
        else
          puts ' - undefined priority: %s' % name
          count += 1
        end
      end
      count
    end

    def prepare_customfields
      @customfields_binding = {}
      redmine_customfields = @connector.custom_fields
      count = 0
      @app_config['CUSTOM_FIELDS'].each do |jira_field, redmine_field|
        puts format(' - processing "%s" -> "%s"', jira_field, redmine_field)
        redmine_customfield = redmine_customfields.find { |v| v[:name].downcase == redmine_field.downcase }
        if !redmine_customfield.nil?
          puts format('  - redmine custom field id assigned: %s', redmine_customfield[:id])
          if jira_field.downcase == JIRA_ISSUE_KEY # special case to map jira issue key
            puts '  - special case, Jira issue key to be used'
            @customfields_binding[JIRA_ISSUE_KEY] = redmine_customfield[:id]
          elsif jira_field.downcase == JIRA_LABEL_KEY # special case to map jira labels
            puts '  - special case, Jira label to be used'
            @customfields_binding[JIRA_LABEL_KEY] = redmine_customfield[:id]
          else
            jirafields = @customfields.select { |_id, name| name.downcase == jira_field.downcase }
            if !jirafields.empty?
              jirafields.each do |k, _v|
                puts format('  - jira custom field id assigned: %s', k)
                @customfields_binding[k] = redmine_customfield[:id]
              end
            else
              puts ' - jira custom field not found!'
              count += 1
            end
          end
        else
          puts '  - redmine custom field not found!'
          count += 1
        end
      end
      count
    end

    def migrate_users
      @user_binding = {}
      redmine_users = @connector.users
      used_email = {}
      @users.each do |id, info|
        puts format(' - found user: %s, %s', info[:login], info[:mail])
        info[:login] = info[:login].strip.downcase
        info[:mail] = format('%s%s', info[:mail].strip.downcase, @app_config['POSTFIX_USER_MAIL_DOMAIN'])
        info[:firstname] = info[:firstname].strip
        info[:lasttname] = info[:lastname].strip
        redmine_user = redmine_users.find { |v| v[:login].downcase == info[:login] }
        if redmine_user.nil? || @app_config['RUNNING_MODE'].between?(2, 3)
          if info[:firstname].empty?
            names = info[:displayname].split(' ', 2)
            if names.count == 2
              info[:firstname] = names[0]
              info[:lastname] = names[1]
            else
              info[:firstname] = info[:displayname]
            end
            info[:firstname] = "Unknown" if info[:firstname].empty?
            info[:lastname] = "Unknown" if info[:lastname].empty?
          end
          if used_email.key?(info[:mail]) || (!redmine_user.nil? && !redmine_users.select { |v| v[:mail] == info[:mail] && redmine_user[:id] != v[:id] }.empty?)
            info[:mail] = SecureRandom.alphanumeric + '_' + info[:mail]
            puts format(' - using fake email "%s" for login "%s" to avoid duplicate', info[:mail], info[:login])
          end
          info[:status] = '1' if @app_config['RUNNING_MODE'] == 2
        end
        if !redmine_user.nil?
          if @app_config['RUNNING_MODE'].between?(2, 3)
            puts ' - updating...'
            # @connector.update_user(redmine_user[:id], { status: info[:status], firstname: info[:firstname], lastname: info[:lastname], mail: info[:mail] })
            @connector.update_user(redmine_user[:id], { status: info[:status] })
          end
        else
          puts ' - adding...'
          redmine_user = @connector.create_user({ login: info[:login], mail: info[:mail], firstname: info[:firstname], lastname: info[:lastname], status: info[:status] })
        end
        used_email[info[:mail]] = info[:login]
        @user_binding[id] = redmine_user[:id]
      end
    end

    def migrate_projects
      @projects_binding = {}
      @versions_binding = {}
      redmine_projects = @connector.projects

      @projects.each do |id, info|
        puts ' - found project: %s' % info.key
        redmine_project = redmine_projects.select { |v| v[:identifier] == info.key.downcase }.first
        if !redmine_project.nil?
          puts ' - project  already exists: "%s"' % redmine_project[:identifier]
        else
          redmine_project = @connector.create_project info.to_h
          raise ' - [Error] Can not create project: "%s"' % info.key if redmine_project.nil?
          puts format(' - created project: "%s"', redmine_project[:identifier])
        end
        if @app_config['INTERNAL_PROJECT_POSTFIX'] != ''
          redmine_project_int = redmine_projects.select { |v| v[:identifier] == (info.key + @app_config['INTERNAL_PROJECT_POSTFIX']).downcase }.first
          if !redmine_project_int.nil?
            puts ' - internal Project  already exists: "%s"' % redmine_project_int[:identifier]
          else
            info_int = info.clone
            info_int.key = info.key + @app_config['INTERNAL_PROJECT_POSTFIX']
            info_int.name = info.name + ' (internal)'
            redmine_project_int = @connector.create_subproject(info_int.to_h, redmine_project[:id])
            raise ' - [Error] Can not create internal project: "%s"' % info_int.key if redmine_project_int.nil?
            puts format(' - created internal project: "%s"', redmine_project_int[:identifier])
          end
        end
        @projects_binding[id] = redmine_project[:id]
        @storage.update_project_link(id, info.key.downcase, redmine_project[:id])
        if @app_config['INTERNAL_PROJECT_POSTFIX'] != ''
          @projects_binding[id + @app_config['INTERNAL_PROJECT_POSTFIX']] = redmine_project_int[:id]
        end
        puts ' - creating project versions...'
        versions = @projectversions.select { |k, v| v.project == id }
        unless versions.empty?
          versions.each do |k, v|
            version = @connector.create_project_version(@projects_binding[id], { name: v.name, description: v.description })
            puts format(' - added %s', v.name)
            @versions_binding[k] = version[:id]
          end
        end
      end
    end

    def migrate_issues
      @issues_binding = {}
      issue_counter = 1
      @issues.each do |id, info|
        puts format(' - found issue: %s, %s of %s', info.key, issue_counter, @issues.count)
        issue_counter += 1
        if @app_config['INTERNAL_PROJECT_POSTFIX'] == '' || info.security.nil? || info.security.empty?
          project_id = info.project
        else
          project_id = info.project + @app_config['INTERNAL_PROJECT_POSTFIX']
        end
        jira_custom_fields = process_custom_fields(id, info)
        version_id = ''
        unless @nodeassociations.empty?
          versionnode = @nodeassociations.find { |as| as[:sourceNodeId] == id && as[:sourceNodeEntity] == 'Issue' && as[:associationType] = 'IssueFixVersion' }
          version_id = @versions_binding[versionnode.sinkNodeId] unless versionnode.nil?
        end
        data = {
          project_id: @projects_binding[project_id],
          tracker_id: @trackers_binding[info.type],
          priority_id: @priorities_binding[info.priority],
          subject: info.summary,
          # description: info.description,
          custom_fields: jira_custom_fields,
          is_private: info.security.nil? || info.security.empty? ? 0 : 1,
          estimated_hours: info.timeoriginalestimate.nil? ? 0 : (info.timeoriginalestimate.to_f / 3600).round(2),
          fixed_version_id: version_id
        }

        redmine_issue = @connector.create_issue data
        raise " - [Error] Can't create issue: %s" % info.key if redmine_issue.nil?

        done_ratio_t = 0
        done_ratio_t = 100 if [3, 5].include?(@statuses_binding[info.status])
        author_user = @user_binding[get_user_id(info.creator)]
        author_user = @app_config['ANONYMOUS_USER_ID'] if author_user.nil?
        @builder.update_issue(redmine_issue[:id], {
                                status_id: @statuses_binding[info.status],
                                created: info.created,
                                updated: info.updated,
                                author_id: author_user,
                                done_ratio: done_ratio_t,
                                duedate: info.duedate.nil? ? '0000-00-00 00:00:00' : info.duedate,
                                description: Base64.encode64(info.description.nil? || info.description.empty? ? '' : RemoveEmoji::Sanitize.call(info.description))
                              })

        comments = @comments.select { |_k, v| v.issue == id }
        if comments.length > 0
          comments.each do |_cid, cinfo|
            comment_user = @user_binding[get_user_id(cinfo.author)]
            comment_user = @app_config['ANONYMOUS_USER_ID'] if comment_user.nil?
            @builder.create_history_event_comment(redmine_issue[:id], {
                                                    user_id: comment_user,
                                                    body: Base64.encode64(cinfo.body.nil? || cinfo.body.empty? ? '' : RemoveEmoji::Sanitize.call(cinfo.body)),
                                                    created: cinfo.created,
                                                    private_notes: cinfo.rolelevel.nil? ? 0 : 1
                                                  })
          end
        end

        worklogs = @worklogs.select { |_k, v| v.issue == id }
        unless worklogs.empty?
          worklogs.each do |_wid, winfo|
            worklog_user = @user_binding[get_user_id(winfo.author)]
            worklog_user = @app_config['ANONYMOUS_USER_ID'] if worklog_user.nil?
            @builder.create_worklog(redmine_issue[:id], {
                                      project_id: @projects_binding[project_id],
                                      user_id: worklog_user,
                                      comments: Base64.encode64(winfo.body.nil? || winfo.body.empty? ? '< No comment >' : RemoveEmoji::Sanitize.call(winfo.body)),
                                      created: winfo.startdate,
                                      hours: winfo.timeworked.nil? ? 0 : (winfo.timeworked.to_f / 3600).round(2),
                                      activity_id: 9
                                    })
          end
        end

        attaches = @attaches.select { |_k, v| v.issue == id }
        if attaches.length > 0
          attaches.each do |aid, ainfo|
            found = true
            attachment_file = File.join(@jirafiles, @projects[info.project].key, info.key, aid)
            unless File.exist? attachment_file
              attachment_file = File.join(@jirafiles, @projects[info.project].key, info.key,
                                          aid + '_' + ainfo[:filename])
            end
            unless File.exist? attachment_file
              attachment_file = File.join(@jirafiles, @projects[info.project].key, '10000', info.key, aid)
            end
            unless File.exist? attachment_file
              attachment_file = File.join(@jirafiles, @projects[info.project].key, '10000', info.key,
                                          aid + '_' + ainfo[:filename])
            end
            unless File.exist? attachment_file
              puts ' - attachment file does not exists: %s!' % attachment_file
              found = false
            end

            unless File.readable? attachment_file
              puts ' - attachment file is not readable: %s!' % attachment_file
              found = false
            end

            next unless found == true

            puts ' - found attachment file: %s' % attachment_file
            filename = format('%s_%s', id, ainfo[:filename])
            destination = File.join(@outputfiles, filename)

            FileUtils.cp(attachment_file, destination)

            sha256 = Digest::SHA256.new
            File.open(destination, 'rb') do |f|
              while buffer = f.read(8192)
                sha256.update(buffer)
              end
            end

            attache_user = @user_binding[get_user_id(ainfo[:author])]
            attache_user = @app_config['ANONYMOUS_USER_ID'] if attache_user.nil?
            @builder.create_history_event_attachments(redmine_issue[:id], {
                                                        name: Base64.encode64(ainfo[:filename]),
                                                        user_id: attache_user,
                                                        filename: Base64.encode64(filename),
                                                        created: ainfo[:created],
                                                        filesize: ainfo[:filesize],
                                                        digest: sha256.hexdigest,
                                                        type: ainfo[:mimetype]
                                                      })
          end
        end

        groups = @history_groups.select { |_k, v| v[:issue] == id }
        unless groups.empty?
          groups.each do |gid, ginfo|
            events = @history.select { |_k, v| v[:group] == gid }
            unless events.empty?
              events.each do |_, einfo|
                if einfo[:field] == 'status'
                  new_value = @statuses_binding[einfo[:newvalue]]
                  old_value = @statuses_binding[einfo[:oldvalue]]
                  if new_value != old_value
                    event_user = @user_binding[get_user_id(ginfo[:author])]
                    event_user = @app_config['ANONYMOUS_USER_ID'] if event_user.nil?
                    @builder.create_history_event_status(redmine_issue[:id], {
                                                           journal_id: redmine_issue[:id],
                                                           user_id: event_user,
                                                           old_value: old_value,
                                                           value: new_value,
                                                           created: ginfo[:created]
                                                         })
                  end
                end
              end
            end
          end
        end

        unless info.assignee.nil?
          @users.each do |k, u|
            next unless u[:login] == info.assignee

            membership = @connector.memberships data[:project_id]
            unless membership.include? @user_binding[k]
              @connector.create_membership(@projects_binding[project_id], {
                                             user_id: @user_binding[k],
                                             role_ids: [@default_role[:id]]
                                           })
            end

            @connector.update_issue redmine_issue[:id], { assigned_to_id: @user_binding[k] }
            # puts '[Redmine API] Issue assigned to %s' % info.assignee
          end
        end

        puts ' - created issue: %s' % info.summary
        @issues_binding[id] = redmine_issue[:id]
        @storage.update_issue_link(id, info.project, info.key, redmine_issue[:id])
      end
      puts 'Processing issue relations...'
      link_counter = 1
      @issuelinks.each do |id, link|
        puts format(' - processing linktype: %s, source: %s, destination: %s, %s of %s', link.linktype, link.destination, link.source, link_counter, @issuelinks.count)
        link_counter += 1
        if @issues_binding[link.source].nil? || @issues_binding[link.destination].nil?
          puts format(' - cross project issue relation from %s to %s added for later processing, use RUNNING_MODE=6...', link.source, link.destination)
          @storage.update_issue_relation(id, link.source, link.destination, link.linktype, 0) # cross-project link, delayed processing
        else
          case link.linktype
          when '10001' # Subtask
            puts format(' - setting issue %s to parent %s', @issues_binding[link.destination], @issues_binding[link.source])
            @connector.update_issue @issues_binding[link.destination], { parent_issue_id: @issues_binding[link.source] }
          else
            link_map = {
              '10000' => 'duplicates', # Duplicate
              '10010' => 'relates', # Similar
              '10020' => 'blocked', # Dependant
              '10030' => 'copied_from', # Clone
              '10130' => 'follows' # Epic Story
              # default "relates"): the type of relation (in: "relates", "duplicates", "duplicated",
              # "blocks", "blocked", "precedes", "follows", "copied_to", "copied_from")
            }
            linktype = 'relates'
            if link_map.key?(link.linktype)
              linktype = link_map[link.linktype]
            else
              puts format(' - no mapping for "%s", resetting to "%s"', link.linktype, linktype)
            end
            puts format(' - setting issue %s as "%s" of %s', @issues_binding[link.destination], linktype, @issues_binding[link.source])
            begin
              # @builder.create_issue_link({ issue_from_id: @issues_binding[link.source], issue_to_id: @issues_binding[link.destination],
              #                             relation_type: linktype })
              @connector.create_issue_link @issues_binding[link.source], { issue_to_id: @issues_binding[link.destination],
                                                                           relation_type: linktype }
            rescue => e
              puts '- failed to set relations, ignored...'
              puts e.message
            end
          end
        end
      end
    end

    def update_cross_project_relations
      @storage.update_relations @connector
    end

    def process_custom_fields(id, info)
      custom_fields = {}
      result_fields = []
      custom_fields[@customfields_binding[JIRA_ISSUE_KEY]] = format('[%s]', info.key) if @customfields_binding.key?(JIRA_ISSUE_KEY)
      if @customfields_binding.key?(JIRA_LABEL_KEY)
        labels = @labels.select { |_k, v| v.issue == id }
        unless labels.empty?
          label = ''
          labels.each { |_k, v| label += format('[%s]', v.label) }
          custom_fields[@customfields_binding[JIRA_LABEL_KEY]] = label
        end
      end
      customvalues = @customfield_values.select { |_k, v| v[:issue] == id }
      unless customvalues.empty?
        customvalues.each do |_k, v|
          custom_fields[@customfields_binding[v[:customfield]]] = v[:stringvalue] if @customfields_binding.key?(v[:customfield])
        end
      end
      custom_fields.each do |k, v|
        result_fields.append({ id: k, value: v }) unless v.nil?
      end
      result_fields
    end

    def load_jira_statuses
      @statuses = {}
      get_list_from_tag('/*/Status', :name, :id).each do |v|
        @statuses[v['id']] = v['name']
      end
      puts format(' - loaded %s', @statuses.count)
    end

    def load_jira_users
      @users = {}
      get_list_from_tag('/*/User', :id, :userName, :emailAddress, :firstName, :lastName, :active, :displayName).each do |v|
        @users[v['id']] = { login: v['userName'].gsub('ø', 'o'),
                            mail: v['emailAddress'], firstname: v['firstName'].gsub('ø', 'o'), lastname: v['lastName'].truncate(30).gsub('ø', 'o'),
                            status: v['active'] == '0' ? '3' : '1', displayname: v['displayName'] }
      end
      puts format(' - loaded %s', @users.count)
    end

    def load_jira_user_aliases
      @user_aliases = {}
      get_list_from_tag('/*/ApplicationUser', :id, :userKey, :lowerUserName).each do |v|
        @user_aliases[v['id']] = { id: v['id'], userKey: v['userKey'], lowerUserName: v['lowerUserName'] }
      end
    end

    def get_user_id(login)
      user = @users.find { |_k, u| u[:login] == login }
      if user.nil? && !@user_aliases.find { |_k, u| u[:userKey] == login }.nil?
        user = @users.find { |_k, u| u[:login] == @user_aliases.find { |_k, u| u[:userKey] == login }[1][:lowerUserName] }
      end
      user[0] unless user.nil?
    end

    def load_jira_types
      @types = {}
      get_list_from_tag('/*/IssueType', :name, :id).each do |v|
        @types[v['id']] = v['name']
      end
      puts format(' - loaded %s', @types.count)
    end

    def load_jira_priorities
      @priorities = {}
      get_list_from_tag('/*/Priority', :name, :id).each do |v|
        @priorities[v['id']] = v['name']
      end
      puts format(' - loaded %s', @priorities.count)
    end

    def load_jira_projects
      @projects = {}
      get_list_from_tag('/*/Project', :id, :name, :key, :lead, :description).each do |v|
        @projects[v['id']] = JiraProject.new(v) if @app_config['PROJECT_TO_IMPORT'].downcase.split(',').include?(v['key'].downcase)
      end
      puts format(' - loaded %s', @projects.count)
    end

    def load_jira_project_versions
      @projectversions = {}
      get_list_from_tag('/*/Version', :id, :project, :name, :description).each do |v|
        @projectversions[v['id']] = JiraProjectVersion.new(v) if @projects.key?(v['project'])
      end
      puts format(' - loaded %s', @projectversions.count)
    end

    def load_jira_issues
      @issues = {}
      get_list_from_tag('/*/Issue', :id, :key, :project, :creator, :assignee, :type,
                        :summary, :description, :priority, :status, :created, :updated,
                        :security, :timeoriginalestimate, :duedate).each do |v|
        @issues[v['id']] = JiraIssue.new(v) if @projects.key?(v['project'])
      end
      puts format(' - loaded %s', @issues.count)
    end

    def load_jira_issue_links
      @issuelinks = {}
      get_list_from_tag('/*/IssueLink', :id, :linktype, :source, :destination).each do |v|
        @issuelinks[v['id']] = JiraIssueLink.new(v) if @issues.key?(v['source'])
      end
      puts format(' - loaded %s', @issuelinks.count)
    end

    def load_jira_comments
      @comments = {}
      get_list_from_tag('/*/Action[@type="comment"]', :id, :issue, :author, :body, :created, :rolelevel).each do |v|
        @comments[v['id']] = JiraComment.new(v) unless v['body'].empty? || !@issues.key?(v['issue'])
      end
      puts format(' - loaded %s', @comments.count)
    end

    def load_jira_worklogs
      @worklogs = {}
      get_list_from_tag('/*/Worklog', :id, :issue, :author, :body, :startdate, :timeworked).each do |v|
        @worklogs[v['id']] = JiraWorklog.new(v) if @issues.key?(v['issue'])
      end
      puts format(' - loaded %s', @worklogs.count)
    end

    def load_jira_attaches
      @attaches = {}
      get_list_from_tag('/*/FileAttachment', :id, :issue, :author, :mimetype, :filename, :created,
                        :filesize).each do |v|
        @attaches[v['id']] = JiraAttache.new(v) if @issues.key?(v['issue'])
      end
      puts format(' - loaded %s', @attaches.count)
    end

    def load_jira_node_associations
      @nodeassociations = []
      get_list_from_tag('/*/NodeAssociation', :sourceNodeId, :sourceNodeEntity, :sinkNodeId, :sinkNodeEntity,
                        :associationType).each do |v|
                          @nodeassociations.push(JiraNodeAssociation.new(v)) if v['associationType'] == 'IssueFixVersion' && @issues.key?(v['sourceNodeId']) # only needed
      end
      puts format(' - loaded %s', @nodeassociations.count)
    end

    def load_jira_history
      # we care about status changes for now
      # history_types = ['status', 'timespent', 'timeestimate', 'attachment', 'fix verion', 'assignee', 'priority', 'timeoriginalestimate', 'duedate', 'description'].to_set
      history_types = ['status'].to_set
      @history_groups = {}
      get_list_from_tag('/*/ChangeGroup', :id, :issue, :author, :created).each do |v|
        @history_groups[v['id']] = JiraHistoryGroup.new(v) if @issues.key?(v['issue'])
      end
      @history = {}
      get_list_from_tag('/*/ChangeItem', :id, :group, :fieldtype, :field, :newvalue, :oldvalue, :newstring, :oldstring).each do |v|
        @history[v['id']] = JiraHistory.new(v) if @history_groups.key?(v['group']) && (history_types.include?(v['field'].downcase))
      end
      puts format(' - loaded %s', @history.count)
    end

    def load_jira_customfields
      @customfields = {}
      get_list_from_tag('/*/CustomField', :id, :name).each do |v|
        @customfields[v['id']] = v['name']
      end
      puts format(' - loaded %s', @customfields.count)
    end

    def load_jira_customfield_values
      @customfield_values = {}
      get_list_from_tag('/*/CustomFieldValue', :id, :issue, :customfield, :stringvalue).each do |v|
        @customfield_values[v['id']] = JiraCustomFieldValue.new(v) if @issues.key?(v['issue']) && @customfields_binding.key?(v['customfield'])
      end
      puts format(' - loaded %s', @customfield_values.count)
    end

    def load_jira_labels
      @labels = {}
      if @customfields_binding.key?(JIRA_LABEL_KEY)
        get_list_from_tag('/*/Label', :id, :issue, :label).each do |v|
          @labels[v['id']] = JiraLabel.new(v) if @issues.key?(v['issue'])
        end
        puts format(' - loaded %s', @labels.count)
      else
        puts format(' - not required, no mapping for "%s" field found', JIRA_LABEL_KEY)
      end
    end

    def get_list_from_tag(query, *attributes)
      ret = []
      temp_ret = []
      @jiraxml.xpath(query).each do |node|
        # Support for CDATA:
        # ret.push(Hash[node.attributes.select do |k, _v|
        #                attributes.empty? || attributes.include?(k.to_sym)
        #              end.map { |k, v| [k, v.content] }])
        temp_ret = Hash[node.attributes.select do |k, _v|
                        attributes.empty? || attributes.include?(k.to_sym)
                      end.map { |k, v| [k, v.content] }]
        node.children.each do |temp_node|
          temp_ret.store(temp_node.name, temp_node.text) if attributes.include?(temp_node.name.to_sym)
        end
        ret.push(Hash[temp_ret])
      end
      ret
    end

    private :prepare_roles, :prepare_statuses, :prepare_trackers, :prepare_priorities, :prepare_customfields,
            :migrate_users, :migrate_projects, :migrate_issues, :update_cross_project_relations,
            :process_custom_fields, :load_jira_statuses, :load_jira_users, :load_jira_user_aliases,
            :get_user_id, :load_jira_types, :load_jira_priorities, :load_jira_projects, :load_jira_project_versions,
            :load_jira_issues, :load_jira_issue_links, :load_jira_comments, :load_jira_worklogs, :load_jira_attaches,
            :load_jira_node_associations, :load_jira_history, :load_jira_customfields,
            :load_jira_customfield_values, :get_list_from_tag
  end
end
