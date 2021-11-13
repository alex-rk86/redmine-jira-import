# Redmine Jira Import

## Introduction
This library has been created to migrate our data from Jira 8.5.5 to Redmine 4.2.3.
Depending on complexity of your Jira configuration and desired quality of imported data
it can be complicated and time consuming task with multuple tries.
Don't expect it to be out of the box solution, you will need to adjust your Redmine configuration,
the import configuration and possibly the source code.  
I hope, the library will give you a good starting point and allow you to adapt it to your needs.

It is based on "jira2redmine" by Kassius Kress (https://github.com/hacpaka/jira2redmine)
with number of improvements and extensions:

- User account status (locked/unlocked) based on Jira active/inactive
- Worklogs import
- Jira Issue key as additional custom field (configurable)
- Project(s) import is done by specifying project codes instead all at once (not practical for large Jira deployments).
- Parsing and normalizing user names, creating unique emails to comply with Redmine requirements.
- Additional lookups for Jira attachments location
- Support for issue sub-tasks
- Support for issue relations, including cross project (delayed processing with SQLite as storage)
- Support for internal/private visibility for issues and notes
- Support for additional issue fields: Added By, Estimated time, Due date
- Setting 100% progress for closed or resolved issues
- Support for CDATA in XML processing
- Handling Jira user aliases (historical changes of user names)
- Support for Project/Issue versions, import Target version
- Issue description update moved from REST to sql being sometimes too long for REST
- Handling attachments with names with special chars
- Performance improvements by selective load, hash vs arrays. etc.
- Adjustments for issue history items and format
- Support for Unassigned issues,  Anonymous user used
- Removing emojis from issue and notes text
- During user creating adding fake '.local' to user domain to block any email sent, configurable
- Removing of history changes with the same status, like In Progress -> In Progress due consolidated statuses.
- Text custom fields support with configurable mapping
- Mostly changed settings moved to config file
- Support for Jira labels (can be mapped to custom field)
- Something I likely forgot...


## Supported
* **Users**
* **Project:**
* **Project members role**
* **Issues**
* **Issues history**
* **Issue labels**
* **Worklogs**
* **Attachments**
* **Subtasks and relations**
* **Project versions**
* **Custom fields**

## Not supported
* **Workflow**

## Environment
* [Jira] v8.5.5
* [Redmine] v4.2.3
* [MariaDB] v10.3

### Configuration
Plese review the docummented config/config.yml.default file.

## How to
Obviously, you will need fresh working Redmine instance.  
(You can check my docker - https://gitlab.rk86.com/alex/redmine-docker)

Add new statuses, trackers you want to map and import from Jira.  
Set new trackers as default for new projects in Administration / Settings / Projects

Add new custom text fields you want to map an import from Jira.  
It is safer to enable them for all trackers.

If you need cross-project relations - enable 'Allow cross-project issue relations'.  
in Administration / Settings / Issue tracking.

Enable Redmine REST web service in Administration / Settings/ API.

As default Redmine has limit to maximum returned records for REST as 100.  
It could cause issues and we need temporarily remove this limitation.

In case of my docker used:

```
docker exec -it `docker ps | grep 'alex-redmine:01' | awk '{ print $1 }'` /bin/bash

nano /opt/bitnami/redmine/app/controllers/application_controller.rb
"...
     if limit < 1
       limit = 25
     #elsif limit > 100
     #  limit = 100
..."

# to restart redmine in docker:
touch /opt/bitnami/redmine/tmp/restart.txt
```

---
Preparing the stage machine

In my case, the import process was consuming around 12GB of RAM due size of Jira XML loaded.  
For testing I was using my wokstations with Redmine running as a docker, and later re-run it on
production environment (prod server + stage machine doing import).

Setting up the stage machine

Get the library from repository:
```
cd ~
git clone https://gitlab.rk86.com/alex/redmine-jira-import.git
cd redmine-jira-import

```

Installing ruby and required gems with bundler

for Ubuntu:

```
sudo apt install ruby-full
gem install --user-install bundler
cd redmine-jira-import
bundle install --path ~/.gem
```

for Arch:

```
sudo pacman -S ruby ruby-irb
```

Add to your shell profile since we want to use user installed gems:  
"...  
export GEM_HOME="$(ruby -e 'puts Gem.user_dir')"  
export PATH="$PATH:$GEM_HOME/bin"  
..."  
Restart your terminal session.

```
gem install bundler
cd redmine-jira-import
bundle install --path ~/.local/share/gem
```

As you noticed, I prefer user gem installations, not system,
but it is really up to you...

Copy all Jira exported XML and attachments to some local directory.

```
cd config
cp config.yml.default config.yml
```

Review and adjust "config.yml"

```
cd ..
cp run.default run
```

Review and adjust "run"

Notice the post processing part there - the import uses Redmine REST plus SQL execution
at the end (plus copying generated attachment files).

```
./run
```

Review the import process, make adjustment, repeat if required.

Typical workflow would be to use the RUNNING_MODE as:
- 0 - initial check
- 1 - importing users only
- 2 - enabling all users
- 4 - importing some project(s)

Review the project import, if not happy - delete the project from Redmine.
Don't forget to run after that RUNNING_MODE = 5 since we want to cleanup
internal storage used for cross-project references.
Adjust settings, re-run RUNNING_MODE = 4.

When happy with result:

- 3 - let's lock accounts disabled in Jira
- 6 - let's set the cross-project relations for imported projects.

When need to import additional projects:

- 2 - let's reactivate all users (required for Redmine to assign issues)
- 4 - import the project

and so on.

Start adjusting user groups, permissions and workflows.

Good luck!



