# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: BUSL-1.1

require 'fileutils'
require "pathname"
require 'vagrant/util/safe_chdir'
require 'vagrant/util/subprocess'
require 'vagrant/util/presence'

module Vagrant
  module Action
    module General
      # A general packaging (tar) middleware. Given the following options,
      # it will do the right thing:
      #
      #   * package.output - The filename of the outputted package.
      #   * package.include - An array of files to include in the package.
      #   * package.info - Path of desired info.json file to include
      #   * package.directory - The directory which contains the contents to
      #       compress into the package.
      #
      # This middleware always produces the final file in the current working
      # directory (FileUtils.pwd)
      class Package
        include Util

        # Perform sanity validations that the provided output filepath is sane.
        # In particular, this function validates:
        #
        #   - The output path is a regular file (not a directory or symlink)
        #   - No file currently exists at the given path
        #   - A directory of package files was actually provided (internal)
        #
        # @param [String] output path to the output file
        # @param [String] directory path to a directory containing the files
        def self.validate!(output, directory)
          filename = File.basename(output.to_s)
          output   = fullpath(output)

          if File.directory?(output)
            raise Vagrant::Errors::PackageOutputDirectory
          end

          if File.exist?(output)
            raise Vagrant::Errors::PackageOutputExists, filename: filename
          end

          if !Vagrant::Util::Presence.present?(directory) || !File.directory?(directory)
            raise Vagrant::Errors::PackageRequiresDirectory
          end
        end

        # Calculate the full path of the given path, relative to the current
        # working directory (where the command was run).
        #
        # @param [String] output the relative path
        def self.fullpath(output)
          File.expand_path(output, Dir.pwd)
        end

        # The path to the final output file.
        # @return [String]
        attr_reader :fullpath

        def initialize(app, env)
          @app = app

          env["package.files"]  ||= {}
          env["package.info"]   ||= ""
          env["package.output"] ||= "package.box"

          @fullpath = self.class.fullpath(env["package.output"])
        end

        def call(env)
          @env = env

          self.class.validate!(env["package.output"], env["package.directory"])

          package_with_folder_path if env["package.output"].include?(File::SEPARATOR)

          raise Errors::PackageOutputDirectory if File.directory?(fullpath)

          raise Errors::PackageInvalidInfo if invalid_info?

          @app.call(env)

          @env[:ui].info I18n.t("vagrant.actions.general.package.compressing", fullpath: fullpath)

          copy_include_files
          copy_info
          setup_private_key
          write_metadata_json
          compress
        end

        def package_with_folder_path
          folder_path = File.expand_path("..", @fullpath)
          create_box_folder(folder_path) unless File.directory?(folder_path)
        end

        def create_box_folder(folder_path)
          @env[:ui].info(I18n.t("vagrant.actions.general.package.box_folder", folder_path: folder_path))
          FileUtils.mkdir_p(folder_path)
        end

        def recover(env)
          @env = env

          # There are certain exceptions that we don't delete the file for.
          ignore_exc = [Errors::PackageOutputDirectory, Errors::PackageOutputExists]
          ignore_exc.each do |exc|
            return if env["vagrant.error"].is_a?(exc)
          end

          # Cleanup any packaged files if the packaging failed at some point.
          File.delete(fullpath) if File.exist?(fullpath)
        end

        # This method copies the include files (passed in via command line)
        # to the temporary directory so they are included in a sub-folder within
        # the actual box
        def copy_include_files
          include_directory = Pathname.new(@env["package.directory"]).join("include")

          @env["package.files"].each do |from, dest|
            # We place the file in the include directory
            to = include_directory.join(dest)

            @env[:ui].info I18n.t("vagrant.actions.general.package.packaging", file: from)
            FileUtils.mkdir_p(to.parent)

            # Copy directory contents recursively.
            if File.directory?(from)
              FileUtils.cp_r(Dir.glob(from), to.parent, preserve: true)
            else
              FileUtils.cp(from, to, preserve: true)
            end
          end
        rescue Errno::EEXIST => e
          raise if !e.to_s.include?("symlink")

          # The directory contains symlinks. Show a nicer error.
          raise Errors::PackageIncludeSymlink
        end

        # This method copies the specified info.json file to the temporary directory
        # so that it is accessible via the 'box list -i' command
        def copy_info
          info_path = Pathname.new(@env["package.info"])

          if info_path.file?
            FileUtils.cp(info_path, @env["package.directory"], preserve: true)
          end
        end

        # Compress the exported file into a package
        def compress
          # Get the output path. We have to do this up here so that the
          # pwd returns the proper thing.
          output_path = fullpath.to_s

          # Switch into that directory and package everything up
          Util::SafeChdir.safe_chdir(@env["package.directory"]) do
            # Find all the files in our current directory and tar it up!
            files = Dir.glob(File.join(".", "*"))

            # Package!
            Util::Subprocess.execute("bsdtar", "-czf", output_path, *files)
          end
        end

        # Write the metadata file into the box so that the provider
        # can be automatically detected when adding the box
        def write_metadata_json
          meta_path = File.join(@env["package.directory"], "metadata.json")
          return if File.exist?(meta_path)

          if @env[:machine] && @env[:machine].provider_name
            provider_name = @env[:machine].provider_name
          elsif @env[:env] && @env[:env].default_provider
            provider_name = @env[:env].default_provider
          else
            return
          end
          File.write(meta_path, {provider: provider_name}.to_json)
        end

        # This will copy the generated private key into the box and use
        # it for SSH by default. We have to do this because we now generate
        # random keypairs on boot, so packaged boxes would stop working
        # without this.
        def setup_private_key
          # If we don't have machine, we do nothing (weird)
          return if !@env[:machine]

          # If we don't have a data dir, we also do nothing (base package)
          return if !@env[:machine].data_dir

          # If we don't have a generated private key, we do nothing
          path = @env[:machine].data_dir.join("private_key")
          if !path.file?
            # If we have a private key that was copied into this box,
            # then we copy that. This is a bit of a heuristic and can be a
            # security risk if the key is named the correct thing, but
            # we'll take that risk for dev environments.
            (@env[:machine].config.ssh.private_key_path || []).each do |p|
              # If we have the correctly named key, copy it
              if File.basename(p) == "vagrant_private_key"
                path = Pathname.new(p)
                break
              end
            end
          end

          # If we still have no matching key, do nothing
          return if !path.file?

          # Copy it into our box directory
          dir = Pathname.new(@env["package.directory"])
          new_path = dir.join("vagrant_private_key")
          FileUtils.cp(path, new_path)

          # Append it to the Vagrantfile (or create a Vagrantfile)
          vf_path = dir.join("Vagrantfile")
          mode = "w+"
          mode = "a" if vf_path.file?
          vf_path.open(mode) do |f|
            f.binmode
            f.puts
            f.puts %Q[Vagrant.configure("2") do |config|]
            f.puts %Q[  config.ssh.private_key_path = File.expand_path("../vagrant_private_key", __FILE__)]
            f.puts %Q[end]
          end
        end

        # Check to see if package.info is a valid file and titled info.json
        def invalid_info?
          if @env["package.info"] != ""
            info_path = Pathname.new(@env["package.info"])

            return !info_path.file? || File.basename(info_path) != "info.json"
          end
        end
      end
    end
  end
end
