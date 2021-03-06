require 'net/http'
require 'dropbox_api'

module Fastlane
  module Actions
    class DropboxAction < Action
      KEYCHAIN_SERVICE_NAME = 'fastlane-plugin-dropbox'.freeze

      def self.run(params)
        UI.message ''
        UI.message "Starting upload of #{params[:file_path]} to Dropbox"
        UI.message ''

        params[:keychain] ||= default_keychain

        write_mode =
          if params[:write_mode].nil?
            'add'
          elsif params[:write_mode].eql? 'update'
            if params[:update_rev].nil?
              UI.user_error! 'You need to specify `update_rev` when using `update` write_mode.'
            else
              DropboxApi::Metadata::WriteMode.new({
                  '.tag' => 'update',
                  'update' => params[:update_rev]
                })
            end
          else
            params[:write_mode]
          end

        access_token = get_token_from_keychain(params[:keychain], params[:keychain_password])
        unless access_token
          access_token = request_token(params[:app_key], params[:app_secret])
          unless save_token_to_keychain(params[:keychain], access_token)
            UI.user_error! 'Failed to store access token in the keychain'
          end
        end

        client = DropboxApi::Client.new(access_token)

        output_file = nil

        chunk_size = 157_286_400 # 150 megabytes

        if File.size(params[:file_path]) < chunk_size
          output_file = upload(client, params[:file_path], destination_path(params), write_mode)
        else
          output_file = upload_chunked(client, chunk_size, params[:file_path], destination_path(params), write_mode)
        end

        if output_file.name != File.basename(params[:file_path])
          UI.user_error! 'Failed to upload file to Dropbox'
        else
          UI.success "File revision: '#{output_file.rev}'"
          UI.success "Successfully uploaded file to Dropbox at '#{destination_path(params)}'"
        end
      end

      def self.upload(client, file_path, destination_path, write_mode)
        begin
          client.upload destination_path, File.read(file_path), mode: write_mode
        rescue DropboxApi::Errors::UploadWriteFailedError => e
          UI.user_error! "Failed to upload file to Dropbox. Error message returned by Dropbox API: \"#{e.message}\""
        end
      end

      def self.upload_chunked(client, chunk_size, file_path, destination_path, write_mode)
        parts = chunker file_path, './part', chunk_size
        UI.message ''
        UI.important "The archive is a big file so we're uploading it in 150MB chunks"
        UI.message ''

        begin
          UI.message "Uploading part #1 (#{File.size(parts[0])} bytes)..."
          cursor = client.upload_session_start File.read(parts[0])
          parts[1..parts.size].each_with_index do |part, index|
            UI.message "Uploading part ##{index + 2} (#{File.size(part)} bytes)..."
            client.upload_session_append_v2 cursor, File.read(part)
          end

          client.upload_session_finish cursor, DropboxApi::Metadata::CommitInfo.new('path' => destination_path,
                                                                                    'mode' => write_mode)
        rescue DropboxApi::Errors::UploadWriteFailedError => e
          UI.user_error! "Error uploading file to Dropbox: \"#{e.message}\""
        ensure
          parts.each { |part| File.delete(part) }
        end
      end

      def self.destination_path(params)
        "#{params[:dropbox_path]}/#{File.basename(params[:file_path])}"
      end

      def self.default_keychain
        `security default-keychain`.chomp.gsub(/.+"(.+)"/, '\\1')
      end

      def self.get_token_from_keychain(keychain, password)
        other_action.unlock_keychain(
          path: keychain,
          password: password
        )
        token = `security find-generic-password -s #{KEYCHAIN_SERVICE_NAME} -w "#{keychain}" 2>/dev/null`.chomp
        $CHILD_STATUS >> 8 == 0 ? token : nil
      end

      def self.save_token_to_keychain(keychain, access_token)
        `security add-generic-password -a #{KEYCHAIN_SERVICE_NAME} -s #{KEYCHAIN_SERVICE_NAME} -w "#{access_token}" "#{keychain}"`
        $CHILD_STATUS >> 8 == 0
      end

      def self.chunker(f_in, out_pref, chunksize)
        parts = []
        File.open(f_in, 'r') do |fh_in|
          until fh_in.eof?
            part = "#{out_pref}_#{format('%05d', (fh_in.pos / chunksize))}"
            File.open(part, 'w') do |fh_out|
              fh_out << fh_in.read(chunksize)
            end
            parts << part
          end
        end
        parts
      end

      def self.request_token(app_key, app_secret)
        sh("open 'https://www.dropbox.com/oauth2/authorize?response_type=code&require_role=work&client_id=#{app_key}'")
        UI.message 'Please autorize fastlane Dropbox plugin to access your Dropbox account via your Dropbox app'
        authorization_code = UI.input('Once authorized, please paste the authorization code here: ')

        uri = URI('https://api.dropboxapi.com/oauth2/token')
        req = Net::HTTP::Post.new(uri)
        req.basic_auth app_key, app_secret
        req.set_form_data(
          'grant_type' => 'authorization_code',
          'code' => authorization_code
        )

        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.request(req)
        end

        case res
        when Net::HTTPSuccess, Net::HTTPRedirection
          json = JSON.parse(res.body)
          access_token = json['access_token']
          UI.success('Successfully authorized fastlane plugin to access Dropbox')
          access_token
        else
          UI.user_error!("Error during authorization with Dropbox: #{res.code} - #{res.body}")
        end
      end

      #####################################################
      # @!group Documentation
      #####################################################

      def self.description
        'Uploads files to Dropbox'
      end

      def self.details
        'You have to authorize the action before using it. The access token is stored in your default keychain'
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :file_path,
                                       env_name: 'DROPBOX_FILE_PATH',
                                       description: 'Path to the uploaded file',
                                       type: String,
                                       optional: false,
                                       verify_block: proc do |value|
                                         UI.user_error!("No file path specified for upload to Dropbox, pass using `file_path: 'path_to_file'`") unless value && !value.empty?
                                         UI.user_error!("Couldn't find file at path '#{value}'") unless File.exist?(value)
                                       end),
          FastlaneCore::ConfigItem.new(key: :dropbox_path,
                                       env_name: 'DROPBOX_PATH',
                                       description: 'Path to the destination Dropbox folder',
                                       type: String,
                                       optional: true),
          FastlaneCore::ConfigItem.new(key: :write_mode,
                                       env_name: 'DROPBOX_WRITE_MODE',
                                       description: 'Determines uploaded file write mode. Supports `add`, `overwrite` and `update`',
                                       type: String,
                                       optional: true,
                                       verify_block: proc do |value|
                                         UI.command_output("write_mode '#{value}' not recognized. Defaulting to `add`.") unless value =~ /(add|overwrite|update)/
                                       end),
          FastlaneCore::ConfigItem.new(key: :update_rev,
                                       env_name: 'DROPBOX_UPDATE_REV',
                                       description: 'Revision of the file uploaded in `update` write_mode',
                                       type: String,
                                       optional: true,
                                       verify_block: proc do |value|
                                         UI.user_error!("Revision no. must be at least 9 hexadecimal characters ([0-9a-f]).") unless value =~ /[0-9a-f]{9,}/
                                       end),
          FastlaneCore::ConfigItem.new(key: :app_key,
                                       env_name: 'DROPBOX_APP_KEY',
                                       description: 'App Key of your Dropbox app',
                                       type: String,
                                       optional: false,
                                       verify_block: proc do |value|
                                         UI.user_error!("App Key not specified for Dropbox app. Provide your app's App Key or create a new app at https://www.dropbox.com/developers if you don't have an app yet.") unless value && !value.empty?
                                       end),
          FastlaneCore::ConfigItem.new(key: :app_secret,
                                       env_name: 'DROPBOX_APP_SECRET',
                                       description: 'App Secret of your Dropbox app',
                                       type: String,
                                       optional: false,
                                       verify_block: proc do |value|
                                         UI.user_error!("App Secret not specified for Dropbox app. Provide your app's App Secret or create a new app at https://www.dropbox.com/developers if you don't have an app yet.") unless value && !value.empty?
                                       end),
          FastlaneCore::ConfigItem.new(key: :keychain,
                                       env_name: 'DROPBOX_KEYCHAIN',
                                       description: 'Path to keychain where the access token would be stored. Will use default keychain if no value is provided',
                                       type: String,
                                       optional: true,
                                       verify_block: proc do |value|
                                         UI.user_error!("Couldn't find keychain at path '#{value}'") unless File.exist?(value)
                                       end),
          FastlaneCore::ConfigItem.new(key: :keychain_password,
                                       env_name: 'DROPBOX_KEYCHAIN_PASSWORD',
                                       description: 'Password to unlock keychain. If not provided, the plugin would ask for password',
                                       type: String,
                                       optional: true)
        ]
      end

      def self.output; end

      def self.return_value
        'nil or error message'
      end

      def self.authors
        ['Dominik Kapusta']
      end

      def self.example_code
        [
          'dropbox(
            file_path: "./path/to/file.txt",
            dropbox_path: "/My Dropbox Folder/Text files",
            write_mode: "add/overwrite/update",
            update_rev: "a1c10ce0dd78",
            app_key: "dropbox-app-key",
            app_secret: "dropbox-app-secret"
          )'
        ]
      end

      def self.is_supported?(_platform)
        true
      end
    end
  end
end
