# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: BUSL-1.1

require "fileutils"
require "log4r"

module VagrantPlugins
  module HyperV
    module Action
      class Import

        VALID_HD_EXTENSIONS = [".vhd".freeze, ".vhdx".freeze].freeze

        def initialize(app, env)
          @app = app
          @logger = Log4r::Logger.new("vagrant::hyperv::import")
        end

        def call(env)
          vm_dir = env[:machine].box.directory.join("Virtual Machines")
          hd_dir = env[:machine].box.directory.join("Virtual Hard Disks")

          if !vm_dir.directory? || !hd_dir.directory?
            @logger.error("Required virtual machine directory not found!")
            raise Errors::BoxInvalid, name: env[:machine].name
          end

          valid_config_ext = [".xml"]
          if env[:machine].provider.driver.has_vmcx_support?
            valid_config_ext << ".vmcx"
          end

          config_path = nil
          vm_dir.each_child do |file|
            if valid_config_ext.include?(file.extname.downcase)
              config_path = file
              break
            end
          end

          if !config_path
            @logger.error("Failed to locate box configuration path")
            raise Errors::BoxInvalid, name: env[:machine].name
          else
            @logger.info("Found box configuration path: #{config_path}")
          end

          image_path = nil
          hd_dir.each_child do |file|
            if VALID_HD_EXTENSIONS.include?(file.extname.downcase)
              image_path = file
              break
            end
          end

          if !image_path
            @logger.error("Failed to locate box image path")
            raise Errors::BoxInvalid, name: env[:machine].name
          else
            @logger.info("Found box image path: #{image_path}")
          end

          env[:ui].output("Importing a Hyper-V instance")
          dest_path = env[:machine].data_dir.join("Virtual Hard Disks").join(image_path.basename).to_s

          options = {
            "VMConfigFile" => Vagrant::Util::Platform.wsl_to_windows_path(config_path).gsub("/", "\\"),
            "DestinationPath" => Vagrant::Util::Platform.wsl_to_windows_path(dest_path).gsub("/", "\\"),
            "DataPath" => Vagrant::Util::Platform.wsl_to_windows_path(env[:machine].data_dir).gsub("/", "\\"),
            "LinkedClone" => !!env[:machine].provider_config.linked_clone,
            "SourcePath" => Vagrant::Util::Platform.wsl_to_windows_path(image_path).gsub("/", "\\"),
            "VMName" => env[:machine].provider_config.vmname,
            "Memory" => env[:machine].provider_config.memory,
            "MaxMemory" => env[:machine].provider_config.maxmemory,
            "Processors" => env[:machine].provider_config.cpus,
          }

          env[:ui].detail("Creating and registering the VM...")
          server = env[:machine].provider.driver.import(options)

          @logger.debug("import result value: #{server.inspect}")

          sid = case server["id"]
                when String
                  server["id"]
                when Array
                  server["id"].first
                else
                  raise TypeError,
                    "Expected String or Array value, received: #{server["id"].class}"
                end

          env[:ui].detail("Successfully imported VM")
          env[:machine].id = sid
          @app.call(env)
        end
      end
    end
  end
end
