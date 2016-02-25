module GoodData
  module VariableUploader
    module DSL

      class Project

        attr_reader :steps

        def self.update(options = {}, &block)
          self.new(options, &block)
        end

        def initialize(options = {}, &block)
          @login = options[:login]
          @password = options[:pass]
          @pid = options[:pid]
          @steps = []
          @server = options[:server]
          @sst_token = options[:sst_token]
          @logger = options[:logger] || Logger.new 'variable_uploader.log', 10, 102400
          instance_eval(&block)
          run
        end

        def run
          # GoodData.logger = Logger.new(STDOUT)
          if @sst_token.nil?
            GoodData.connect login: @login, password: @password, server: @server, timeout: 30
          else
            GoodData.connect sst_token: @sst_token, server: @server, timeout: 30
          end

          p = GoodData.use(@pid)

          steps.each do |step|
            step.run(@logger, p)
          end
        end

        def update_variable(options={})
          raise "Specify file name or values" if (options[:values].nil? && options[:file].nil?)
          raise "Variable needs to be defined" if options[:variable].nil?

          @steps << VariableStep.new(options[:file], options[:variable], options[:label], options)
        end

        def update_muf(options)
          @steps << MufStep.new(options)
        end

        alias :upload :update_variable

      end

    end
  end
end
