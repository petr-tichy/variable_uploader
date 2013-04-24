module GoodData
  module VariableUploader

    class MufStep < Step

      attr_accessor :config, :file, :id_field, :cache_token

      def initialize(options={})
        puts "initialize"
        @config = options[:config]
        @file = options[:file]
        @id_field = options[:id_field]
        @cache_token = options[:cache_token]
        @users_data = options[:users_data]
      end

      def build_elements_dictionary(uri)
        dictionary = {}
        GoodData.get(uri)["attributeElements"]["elements"].each do |item|
          dictionary[item["title"]] = item["uri"]
        end
        dictionary
      end

      def create_expression(values, attr_uri, elements, user)
        reduced_values = values.inject([]) do |memo, v|
          if elements.has_key?(v) && v != "TRUE"
            memo << elements[v]
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

      
      def create_users_lookup(project)
        users_lookup = {}
        data = @users_data.nil?() ? GoodData.get("#{project.uri}/users") : @users_data
        data["users"].each do |user|
          user = user["user"]
          users_lookup[user["content"]["email"].downcase] = user["links"]["self"]
        end
        users_lookup
      end
      
      
      def run(logger_param, project)

        users_muf_value_filename = cache_token.nil? ? "users_muf_value.json" : "users_muf_value_#{cache_token}.json"
        users_muf_filename       = cache_token.nil? ? "users_muf.json" : "users_muf_#{cache_token}.json"

        csv_headers = config.collect {|i| i[:csv_header]}
        config.each {|i| i[:elements] = build_elements_dictionary(i[:label_uri])}

        sf_data = []

        CSV.foreach(@file, :headers => true, :return_headers => true) do |row|
          if row.header_row?
            (csv_headers + [id_field]).each do |header|
              fail "There is no field #{header} in the file #{file}" unless row.fields.include?(header)
            end
          else
            sf_data << row.to_hash
          end
        end

        puts "Getting users"
        users_in_gd = create_users_lookup(project)

#         GoodData.get("/gdc/projects/#{project.obj_id}/users")["users"].each do |user|
#           users_in_gd[user["user"]["content"]["email"]] = user["user"]["links"]["self"]
#         end

        # Which user has which filter so I do not need to grab them every time
        users_muf = File.exist?(users_muf_filename) ? JSON.parse(File.open(users_muf_filename).read) : {}
        
        users_muf_temp = {}
        
        if (users_muf.respond_to?("each")) then 
          users_muf.each do |key,value|
            users_muf_temp[key.downcase] = value
          end
          users_muf = users_muf_temp
        end

        # Which user has which value of filter so I can compare if it changed
        users_muf_value = File.exist?(users_muf_value_filename) ? JSON.parse(File.open(users_muf_value_filename).read) : {}

        
        if (users_muf_value.respond_to?("each")) then 
          users_muf_value_temp = {}
          users_muf_value.each do |key,value|
            users_muf_value_temp[key.downcase] = value
          end
          users_muf_value = users_muf_value_temp
        end
        
        
        count = 0
        
        # Since users can eventually have more than one value for an attribute we first need to preprocess the data. The format tha should facilitate this should be row oriented
        # Id,Color
        # tomas@email.com,blue
        # tomas@email.com,red
        # 
        # This says that tomas have blue and red color

        accumulated_data = {}
        sf_data.each do |row|
          email = row[id_field].downcase
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
          end
          
        end
        
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
            expression = expression_bits.reduce([]) {|memo, bit| memo << bit unless memo.include?(bit); memo }.join(" AND ")
            puts "#{email} => #{expression}"
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
        File.open(users_muf_value_filename, 'w') do |f|
          f.write JSON.pretty_generate(users_muf_value)
        end

        File.open(users_muf_filename, 'w') do |f|
          f.write JSON.pretty_generate(users_muf)
        end
      end

    end
  end
end


