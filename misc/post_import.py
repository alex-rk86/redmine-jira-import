#!/usr/bin/python
# Simple hack for post processing for missed custom fields on initial import
# Export data, something like:
# docker exec -i (mysql docker id)  mysql -u bn_redmine -p(yourpassword) bitnami_redmine -e "SELECT c_key.value, TO_BASE64(c.value) FROM custom_values c, custom_values c_key, issues i WHERE c.custom_field_id = 18 AND c_key.custom_field_id = 1 AND c.customized_id = i.id AND c_key.customized_id = i.id AND i.project_id = 10 AND c.value !='' AND c.value != '1)';" > to_import.txt
# or from Jira database, the expected lines in to_import.txt:
# [ISSUE-1619]	KzEpIFRlbGVwaG9uZSAxIGFuZCAyIC0gbGV0J3MgcHV0IHRoZW0gb24gc2luZ2xlIGxpbmUgdG8g\nc2F2ZSB2ZXJ0aWNhbCBzcGFjZQ

#Import data, something like:
# cat to_import.sql | docker exec -i (mysql docker id)  mysql -u bn_redmine -p(yourpassword) bitnami_redmine'

import sqlite3
custom_field_id = 18 #custom field it to import data to
connection = sqlite3.connect("storage.db")
cursor = connection.cursor()
with open ('to_import.txt') as f:
    lines = f.readlines()
sqlfile = open ('to_import.sql', 'w')
for line in lines:
    values = line.split()
    values[0] = values[0].replace("[", "").replace("]", "")
    redmine_id = cursor.execute("SELECT redmine_id FROM issue_link WHERE key = ?", (values[0],),).fetchone()[0]
    sql = "DELETE FROM custom_values WHERE custom_field_id = %s AND custom_values.customized_id = %s;\n" % (custom_field_id, redmine_id)
    sql += "INSERT INTO custom_values (customized_type, customized_id, custom_field_id, value) VALUES ('Issue', %s, %s, FROM_BASE64('%s'));\n" % (redmine_id, custom_field_id, values[1])
    sqlfile.write(sql)
connection.close()
sqlfile.close()
