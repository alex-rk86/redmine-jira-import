require 'yaml'
@app_config = YAML.load_file('./config/config.yml')
@builderlib = './lib/builder_' + @app_config['SQL_OUTPUT_FILE_DIALECT'] + '.rb'
require @builderlib
