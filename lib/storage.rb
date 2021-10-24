require 'sqlite3'

namespace :jira do
  class Storage
    def initialize(sqlitefile)
      @db = SQLite3::Database.open sqlitefile
      @db.execute 'CREATE TABLE IF NOT EXISTS project_link (id INT PRIMARY KEY, code TEXT, redmine_id INT)'
      @db.execute 'CREATE TABLE IF NOT EXISTS issue_link (id INT PRIMARY KEY, project_id INT, key TEXT, redmine_id INT)'
      @db.execute 'CREATE TABLE IF NOT EXISTS issue_relation (id INT PRIMARY KEY, source_id INT, target_id INT, linktype INT, status INT)'
      @db.results_as_hash = true
    end

    def update_project_link(id, code, redmine_id)
      @db.execute 'INSERT OR IGNORE INTO project_link (id) VALUES (?)', id
      @db.execute 'UPDATE project_link SET code = ?, redmine_id = ? WHERE id = ?', code, redmine_id, id
    end

    def update_issue_link(id, project_id, key, redmine_id)
      @db.execute 'INSERT OR IGNORE INTO issue_link (id) VALUES (?)', id
      @db.execute 'UPDATE issue_link SET project_id = ?, key = ?, redmine_id = ? WHERE id = ?', project_id, key, redmine_id, id
    end

    def cleanup_project(codes)
      codes.split(',').each do |s|
        puts format(' - cleaning project: "%s"', s)
        @db.execute 'DELETE FROM issue_relation WHERE source_id IN (SELECT il.id FROM issue_link il, project_link pl WHERE il.project_id = pl.id AND pl.code = ?)', s
        @db.execute 'UPDATE issue_relation SET STATUS =0 WHERE target_id IN (SELECT il.id FROM issue_link il, project_link pl WHERE il.project_id = pl.id AND pl.code = ?)', s
        @db.execute 'DELETE FROM issue_link WHERE project_id IN (SELECT id FROM project_link WHERE code = ?)', s
        @db.execute 'DELETE FROM project_link WHERE code = ?', s
      end
    end

    def update_issue_relation(id, source_id, target_id, linktype, status)
      @db.execute 'INSERT OR IGNORE INTO issue_relation (id) VALUES (?)', id
      @db.execute 'UPDATE issue_relation SET source_id = ?, target_id = ?, linktype = ?, status = ? WHERE id = ?', source_id, target_id, linktype, status, id
    end

    def update_relations(connector)
      puts format('Not processed (missing target) relations for:')
      rs = @db.query 'SELECT issue_link.key FROM issue_relation, issue_link WHERE issue_relation.source_id = issue_link.id AND issue_relation.status = 0'
      while (row = rs.next) do
        print format('%s ', row['key'])
      end
      rs = @db.query 'SELECT count(*) as count FROM issue_relation WHERE status = 0'
      puts format(' - not processed total: %s', rs.next['count'])
      puts
      rs = @db.query 'SELECT r.id, r.linktype, lt.key as target_key, lt.redmine_id as target_id, ls.key as source_key, ls.redmine_id as source_id FROM issue_relation r INNER JOIN issue_link lt ON r.target_id = lt.id INNER JOIN issue_link ls ON r.source_id = ls.id WHERE r.STATUS = 0'
      while (row = rs.next) do
        puts format('Setting cross project reference %s -> %s ...', row['source_key'], row['target_key'])
        puts format('- linktype: %s, source: %s, destination: %s', row['linktype'], row['source_id'], row['target_id'])
        case row['linktype']
          when 10001 # Subtask
            puts format('Setting issue %s to parent %s', row['target_id'], row['source_id'])
            connector.update_issue row['target_id'], { parent_issue_id: row['source_id'] }
          else
            link_map = {
              10000 => 'duplicates', # Duplicate
              10010 => 'relates', # Similar
              10020 => 'blocked', # Dependant
              10030 => 'copied_from', # Clone
              10130 => 'follows' # Epic Story
              # default "relates"): the type of relation (in: "relates", "duplicates", "duplicated",
              # "blocks", "blocked", "precedes", "follows", "copied_to", "copied_from")
            }
            linktype = 'relates'
            if link_map.key?(row['linktype'])
              linktype = link_map[row['linktype']]
            else
              puts format('  - no mapping for "%s", resetting to "%s"', link.linktype, linktype)
            end
            puts format('Setting issue %s as "%s" of %s', row['target_id'], linktype, row['source_id'])
            begin
              connector.create_issue_link row['source_id'], { issue_to_id: row['target_id'], relation_type: linktype }
              @db.execute 'UPDATE issue_relation SET STATUS = 1 WHERE id = ?', row['id']
            rescue => e
              puts '- failed to set relations, ignored...'
              puts e.message
            end
        end
      end
    end
  end
end
