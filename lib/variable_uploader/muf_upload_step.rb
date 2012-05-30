module GoodData
  module VariableUploader

    class MufStep < Step

      attr_accessor :config, :file, :id_field

      def initialize(options={})
        puts "initialize"
        @config = options[:config]
        @file = options[:file]
        @id_field = options[:id_field]
      end

      def build_elements_dictionary(uri)
        dictionary = {}
        GoodData.get(uri)["attributeElements"]["elements"].each do |item|
          dictionary[item["title"]] = item["uri"]
        end
        dictionary
      end

      def create_expression(values, attr_uri, elements, user)
        # 
        reduced_values = values.inject([]) do |memo, v|
          if elements.has_key?(v.to_s)
            memo << elements[v.to_s]
          else
            puts "#{v} not found for #{user}" 
          end
          memo
        end
        if reduced_values.empty?
          "TRUE"
        else
          vals = reduced_values.map {|v| "[#{v}]"}.join(',')
          "[#{attr_uri}] IN (#{vals})"
        end
      end

      def create_filter_json(title, expression)
        filter = {
          "userFilter" => {
            "content" => {
              "expression" => expression
            },
            "meta" => {
              "category" => "userFilter",
              "title" => title
            }
          }
        }
      end

      def set_user_filter(user_url, filter_url, project)
        user_filter = {
          "userFilters" => {
            "items" => [
              {
                "user" => user_url,
                "userFilters" => [ filter_url ]
              }
            ]
          }
        }
        GoodData.post "/gdc/md/#{project.obj_id}/userfilters", user_filter
      end

      def run(logger_param, project)
        
        csv_headers = config.collect {|i| i[:csv_header]}
        config.each {|i| i[:elements] = build_elements_dictionary(i[:label_uri])}

        sf_data = []

        FasterCSV.foreach(file, :headers => true, :return_headers => false) do |row|
          # sf_data << row.values_at('user', 'Id', 'Good_Data_Access__c', 'Sales_Region__c', 'Sales_Market__c', 'Sales_Team__c', 'Sales_Mgr_Rptn__c', 'Sales_Terr__c')
          #Id,Sales_Region__c,Sales_Market__c,Sales_Team__c,Sales_Mgr_Rptn__c,Sales_Terr__c,user
          sf_data << row.to_hash
        end
        # binding.pry

        puts "Getting users"
        users_in_gd = {}
        GoodData.get("/gdc/projects/#{project.obj_id}/users")["users"].each do |user|
          users_in_gd[user["user"]["content"]["email"]] = user["user"]["links"]["self"]
        end

        # Which user has which filter so I do not need to grab them every time
        users_muf = File.exist?('users_muf.json') ? JSON.parse(File.open('users_muf.json').read) : {}

        # Which user has which value of filter so I can compare if it changed
        users_muf_value = File.exist?('users_muf_value.json') ? JSON.parse(File.open('users_muf_value.json').read) : {}

        count = 0
        
        # Since users can eventually have more than one value for an attribute we first need to preprocess the data. The format tha should facilitate this should be row oriented
        # Id,Color
        # tomas@email.com,blue
        # tomas@email.com,red
        # 
        # This says that tomas have blue and red color

        accumulated_data = {}
        sf_data.each do |row|
          email = row[id_field]
          is_in_gd = users_in_gd[email] != nil
          puts "#{email} not in gooddata" unless is_in_gd
          next unless is_in_gd

          # Create a place for a user if this is the first time we see it
          accumulated_data[email] = {} unless accumulated_data.has_key?(email)

          expression_bits = config.each do |c|
            header = c[:csv_header]
            if accumulated_data[email].has_key?(header) then
              accumulated_data[email][header] << row[header]
            else
              accumulated_data[email][header] = [row[header]]
            end
            # accumulated_data[email]
            # create_expression(row[c[:csv_header]], c[:attribute], c[:elements], row)
          end
          
        end
        
        pp accumulated_data
        accumulated_data.each do |email, data|
        
          # email = row[id_field]
          muf_uri = users_muf[email]
          # is_in_gd = users_in_gd[email] != nil
          user_url = users_in_gd[email]
          old_muf_value = users_muf_value[email]
          # puts "#{email} not in gooddata" unless is_in_gd
          # next unless is_in_gd
          
          begin
            expression_bits = []
            expression_bits = config.map do |c|
              create_expression(data[c[:csv_header]], c[:attribute], c[:elements], email)
            end
            expression = expression_bits.join(" AND ")
            puts expression
            if muf_uri.nil?
              puts "create a filter for user #{email} and assign. Mark his uri for future reference"
              result = GoodData.post("/gdc/md/#{project.obj_id}/obj", create_filter_json("filter for #{email}", expression))
              users_muf[email] = muf_uri = result["uri"]
              users_muf_value[email] = expression
              set_user_filter(user_url, muf_uri, project)
            elsif expression != old_muf_value
              puts "Updating #{email} with #{expression}"
              GoodData.post(muf_uri, create_filter_json("filter for #{email}", expression))
              users_muf_value[email] = expression
            else
              puts "#{email} has the same value. Not updating"
            end
          rescue RuntimeError => e
            puts e.inspect
          end
          count += 1
        
        end

        # Serialize muf_values
        File.open('users_muf_value.json', 'w') do |f|
          f.write JSON.pretty_generate(users_muf_value)
        end

        File.open('users_muf.json', 'w') do |f|
          f.write JSON.pretty_generate(users_muf)
        end
      end

    end
  end
end

