# Copyright 2013 Google Inc. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
require "log4r"
require "vagrant/util/subprocess"
require "vagrant/util/scoped_hash_override"
require "vagrant/util/which"

module VagrantPlugins
  module Google
    module Action
      # This middleware uses `rsync` to sync the folders over to the
      # Google instance.
      class SyncFolders
        include Vagrant::Util::ScopedHashOverride

        def initialize(app, env)
          @app    = app
          @logger = Log4r::Logger.new("vagrant_google::action::sync_folders")
        end

        def call(env) # rubocop:disable Metrics/MethodLength
          @app.call(env)

          ssh_info = env[:machine].ssh_info

          env[:machine].config.vm.synced_folders.each do |id, data|
            data = scoped_hash_override(data, :google)

            # Ignore disabled shared folders
            next if data[:disabled]

            unless Vagrant::Util::Which.which('rsync')
              env[:ui].warn(I18n.t('vagrant_google.rsync_not_found_warning'))
              break
            end

            hostpath  = File.expand_path(data[:hostpath], env[:root_path])
            guestpath = data[:guestpath]

            # Make sure there is a trailing slash on the host path to
            # avoid creating an additional directory with rsync
            hostpath = "#{hostpath}/" if hostpath !~ /\/$/

            # on windows rsync.exe requires cygdrive-style paths
            if Vagrant::Util::Platform.windows?
              hostpath = hostpath.gsub(/^(\w):/) { "/cygdrive/#{$1}" }
            end

            env[:ui].info(I18n.t("vagrant_google.rsync_folder",
                                 :hostpath => hostpath,
                                 :guestpath => guestpath))

            # Create the guest path
            env[:machine].communicate.sudo("mkdir -p '#{guestpath}'")
            env[:machine].communicate.sudo(
              "chown #{ssh_info[:username]} '#{guestpath}'")

            # patch from https://github.com/tmatilai/vagrant-aws/commit/4a043a96076c332220ec4ec19470c4af5597dd51
            def ssh_key_options(ssh_info)
              # Ensure that `private_key_path` is an Array (for Vagrant < 1.4)
              Array(ssh_info[:private_key_path]).map { |path| "-i '#{path}' " }.join
            end

            #collect rsync excludes specified :rsync__excludes=>['path1',...] in synced_folder options
            excludes = ['.vagrant/', *Array(data[:rsync__excludes])]

            # Rsync over to the guest path using the SSH info
            command = [
              "rsync", "--verbose", "--archive", "-z",
              *excludes.map{|e| ['--exclude', e]}.flatten,
              "-e", "ssh -p #{ssh_info[:port]} -o StrictHostKeyChecking=no #{ssh_key_options(ssh_info)}",
              hostpath,
              "#{ssh_info[:username]}@#{ssh_info[:host]}:#{guestpath}"]

            # we need to fix permissions when using rsync.exe on windows, see
            # http://stackoverflow.com/questions/5798807/rsync-permission-denied-created-directories-have-no-permissions
            if Vagrant::Util::Platform.windows?
              command.insert(1, "--chmod", "ugo=rwX")
            end

            r = Vagrant::Util::Subprocess.execute(*command)
            if r.exit_code != 0
              raise Errors::RsyncError,
                    :guestpath => guestpath,
                    :hostpath => hostpath,
                    :stderr => r.stderr
            end
          end
        end
      end
    end
  end
end
