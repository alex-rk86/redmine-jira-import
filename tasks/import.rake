require './lib/import'
require './lib/connector'

task :import do
  Import.new.migrate
end
