namespace :jira do
  class Builder
    def initialize(sqlfile)
      @file = sqlfile
    end

    def store(string)
      File.write(@file, string + "\n", mode: 'a')
    end

    def update_issue(id, data)
      store(format(
              "UPDATE `issues` SET `created_on` = TIMESTAMP('%s'), start_date=TIMESTAMP('%s'), updated_on = TIMESTAMP('%s'), `status_id` = %s, `author_id` = %s, `done_ratio` = %s, `due_date` = TIMESTAMP('%s') WHERE id = %s;", data[:created], data[:created], data[:updated], data[:status_id], data[:author_id], data[:done_ratio], data[:duedate], id
            ))
      store(format(
              "UPDATE `journals` set `created_on` = TIMESTAMP('%s') WHERE `journalized_type`='Issue' AND `journalized_id`='%s';", data[:created], id
            ))
    end

    def create_history_event_status(id, data)
      store(format(
        "INSERT INTO `journals` (`journalized_id`, `journalized_type`, `user_id`, `notes`, `created_on`) VALUES (%s, 'Issue', %s, '', TIMESTAMP('%s'));", id, data[:user_id], data[:created]
            ))
      store(format(
              "INSERT INTO `journal_details` (`journal_id`, `property`, `prop_key`, `old_value`, `value`) VALUES (LAST_INSERT_ID(), 'attr', 'status_id', '%s', '%s');", data[:old_value], data[:value]
            ))
    end

    def create_history_event_attachments(id, data)
      store(format(
              "INSERT INTO `attachments` (`container_id`, `description`, `author_id`, `container_type`, `filename`, `disk_filename`, `disk_directory`, `filesize`, `content_type`, `digest`, `created_on`) VALUES (%s, '', %s, 'Issue', FROM_BASE64('%s'), FROM_BASE64('%s'), 'jira', '%s', '%s', '%s', TIMESTAMP('%s'));", id, data[:user_id], data[:name], data[:filename], data[:filesize], data[:type], data[:digest], data[:created]
            ))
      store('SELECT LAST_INSERT_ID() INTO @PROP_KEY;')
      store(format(
              "INSERT INTO `journals` (`journalized_id`, `journalized_type`, `user_id`, `notes`, `created_on`) VALUES (%s, 'Issue', %s, '', TIMESTAMP('%s'));", id, data[:user_id], data[:created]
            ))
      store(format(
              "INSERT INTO `journal_details` (`journal_id`, `property`, `prop_key`, `value`) VALUES (LAST_INSERT_ID(), 'attachment', @PROP_KEY, FROM_BASE64('%s'));", data[:name]
            ))
    end

    def create_history_event_comment(id, data)
      store(format(
        "INSERT INTO `journals` (`journalized_id`, `journalized_type`, `user_id`, `notes`, `created_on`, `private_notes`) VALUES (%s, 'Issue', %s, FROM_BASE64('%s'), TIMESTAMP('%s'), %s);", id, data[:user_id], data[:body], data[:created], data[:private_notes]
      ))
    end

    def create_worklog(id, data)
      store(format(
              "INSERT INTO `time_entries` (`project_id`, `author_id`, `user_id`, `issue_id`, `hours`, `comments`, `activity_id`, `spent_on`, `tyear`, `tmonth`, `tweek`, `created_on`, `updated_on`) VALUES (%s, %s, %s, %s, %s, LEFT(FROM_BASE64('%s'), 1024), %s, TIMESTAMP('%s'), YEAR(TIMESTAMP('%s')), MONTH(TIMESTAMP('%s')), WEEK(TIMESTAMP('%s')), TIMESTAMP('%s'), TIMESTAMP('%s'));", data[:project_id], data[:user_id], data[:user_id], id, data[:hours], data[:comments], data[:activity_id], data[:created], data[:created], data[:created], data[:created], data[:created], data[:created]
            ))
    end

    def create_issue_link(data)
      store(format(
              "INSERT INTO `issue_relations` (`issue_from_id`, `issue_to_id`, `relation_type`) VALUES (%s, %s, '%s');", data[:issue_from_id], data[:issue_to_id], data[:relation_type]
            ))
    end

    private :store
  end
end
