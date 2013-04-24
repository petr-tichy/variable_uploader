unless RUBY_VERSION =~ /1.9/
  require 'fastercsv'
  CSV = FasterCSV
else
  require 'csv'
end

require 'gooddata'
require 'pp'
require 'logger'
require 'variable_uploader/dsl'
require 'variable_uploader/step'
require 'variable_uploader/variable_upload_step'
require 'variable_uploader/muf_upload_step'
require 'variable_uploader/user_create_step'
require 'variable_uploader/sf_helper'


module GoodData
  module VariableUploader

  end
end
