# Provider for installing and querying packages with IBM Installation
# Manager.  This could almost be a provider for the package resource, but I'm
# not sure how.  We need to be able to support multiple installations of the
# exact same package of the exact same version but in different locations.
#
# This could also use some work.  I'm obviously lacking in Ruby experience and
# familiarity with the Puppet development APIs.
#
# Right now, this is pretty basic - we can check the existence of a package
# and install/uninstall it.  We don't support updating here.  Updating is
# less than trivial.  Updates are done by the user downloading the massive
# IBM package and extracting it in the right way.  For things like WebSphere,
# several services need to be stopped prior to updating.
#
# Version numbers are also weird.  We're using Puppet's 'versioncmp' here,
# which appears to work for IBM's scheme.  Basically, if the specified version
# or a higher version is installed, we consider the resource to be satisfied.
# Specifically, if the specified path has the specified version or greater
# installed, we're satisfied.
#
# IBM Installation Manager keeps an XML file at
# /var/ibm/InstallationManager/installed.xml that includes all the installed
# packages, their locations, "fixpacks", and other useful information. This
# appears to be *much* more useful than the 'imcl' tool, which doesn't return
# terribly useful information (and it's slower).
#
# We attempt to make an educated guess for the location of 'imcl' by parsing
# that XML file.  Otherwise, the user can explicitly provide that via the
# 'imcl_path' parameter.
#
# A user can provide a 'response file' for installation, which will include
# pretty much *all* the information for installing - paths, versions,
# repositories, etc.  Otherwise, they can provide values for the other
# parameters.  Finally, they can provide their own arbitrary options.
#
require 'rexml/document'
include REXML

Puppet::Type.type(:ibm_pkg).provide(:imcl) do
  desc 'Provides ibm package manager support'

  commands kill: 'kill'
  commands chown: 'chown'
  # presumbly this could work on windows but we have some hard coded paths which
  # breaks these things on windows where the paths are different.
  confine  true: Facter.value(:kernel) != 'windows'

  mk_resource_methods

  # returns the path to the command
  # this is required because it is unlikely that the system would have this in the path
  #
  # @return [String] path to imcl executable
  def imcl_command_path
    unless @imcl_command_path
      if resource[:imcl_path]
        @imcl_command_path = resource[:imcl_path]
      else
        installed = File.open(self.class.installed_file(resource[:user]))
        doc = REXML::Document.new(installed)
        path = XPath.first(doc, '//installInfo/location[@id="IBM Installation Manager"]/@path').value
        installed.close
        @imcl_command_path = File.join(path, 'tools', 'imcl')
      end
    end
    # ensure the execution bit is set
    raise("#{@imcl_command_path} file does not exist") unless File.exist?(@imcl_command_path)
    raise("#{@imcl_command_path} is not executible, use chmod") unless File.open(@imcl_command_path) { |f| f.stat.executable? }
    @imcl_command_path
  end

  # finds a user's home directory
  #
  # @param [String] user
  #   Unix username
  #
  # @return [String] path to a given user's home
  def self.find_user_home(user)
    system_users = Puppet::Type.type(:user).instances
    user_resource = system_users.find { |u| u.name == user }
    return user_resource.provider.home unless user_resource.nil? || user_resource.provider.home.empty?
    raise("Could not find home directory for user #{user}")
  end

  # searches for installed.xml in potential appDataLocation dirs
  #
  # @return [String] installed.xml path if it is found
  def self.find_installed_xml(user)
    require 'find'

    installed_xml_path = nil
    user_home = find_user_home(user) unless user == 'root'

    user_path = if user == 'root'
                  '/var/ibm/'
                else
                  "#{user_home}/var/ibm/"
                end

    if File.exist? user_path
      Find.find(user_path) { |path| installed_xml_path = path if path =~ %r{InstallationManager/installed.xml$} }
    end

    return installed_xml_path if File.file?(installed_xml_path)
    raise("Could not find installed.xml file at #{user_path}/InstallationManager/installed.xml")
  end

  # returns a file handle by opening the install file
  # easier to mock when extracted to method like this
  #
  # @return [String] path to installed.xml file
  def self.installed_file(user)
    file = find_installed_xml(user)
    return file unless file.nil?
    raise('No installed.xml found.')
  end

  # wrapper for imcl command
  #
  # @param [String] cmd_options - options to be passed to the imcl command
  def imcl(cmd_options)
    cwd = Dir.pwd
    Dir.chdir(Dir.home(resource[:user]))
    command = "#{imcl_command_path} #{cmd_options}"
    Puppet::Util::Execution.execute(command, uid: resource[:user], combine: true, failonfail: true)
    Dir.chdir(cwd)
  end

  # get correct `ps` command based on operating system
  #
  # @return [String] string form of ps command with appropriate flags
  def getps
    case Facter.value(:operatingsystem)
    when 'OpenWrt'
      'ps www'
    when 'FreeBSD', 'NetBSD', 'OpenBSD', 'Darwin', 'DragonFly'
      'ps auxwww'
    else
      'ps -ef'
    end
  end

  ## The bulk of this is from puppet/lib/puppet/provider/service/base
  ## IBM requires that all services be stopped prior to installing software
  ## to the target. They won't do it for you, and there's not really a clear
  ## way to say "stop everything that matters".  So for now, we're just
  ## going to search the process table for anything that matches our target
  ## directory and kill it.  We've got to come up with something better for
  ## this.
  def stopprocs
    ps = getps
    regex = Regexp.new(resource[:target])
    debug "Executing '#{ps}' to find processes that match #{resource[:target]}"
    pid = []
    IO.popen(ps) do |table|
      table.each_line do |line|
        next unless regex.match(line)
        debug "Process matched: #{line}"
        ary = line.sub(%r{^\s+}, '').split(%r{\s+})
        pid << ary[1]
      end
    end

    ## If a PID matches, attempt to kill it.
    return if pid.empty?
    pids = ''
    pid.each do |thepid|
      pids += "#{thepid} "
    end
    begin
      debug "Attempting to kill PID #{pids}"
      command = "/bin/kill #{pids}"
      output = Puppet::Util::Execution.execute(command, combine: true, failonfail: false)
    rescue Puppet::ExecutionFailure
      err = <<-EOF
      Could not kill #{name}, PID #{pids}.
      In order to install/upgrade to specified target: #{resource[:target]},
      all related processes need to be stopped.
      Output of 'kill #{pids}': #{output}
      EOF
      @resource.fail Puppet::Error, err, $ERROR_INFO
    end
  end

  # returns target, version and package by reading the response file
  def self.response_file_properties(response_file)
    raise("Cannot open response file #{response_file}") unless File.exist?(response_file)
    resp = {}
    debug("Reading the response file at : #{response_file}")
    begin
      File.open(response_file) do |file|
        doc = REXML::Document.new(file)
        resp[:repository] = XPath.first(doc, '//agent-input/server/repository').attributes['location']
        resp[:target] = XPath.first(doc, '//agent-input/profile').attributes['installLocation']
        resp[:version] = XPath.first(doc, '//agent-input/install/offering').attributes['version']
        resp[:package] = XPath.first(doc, '//agent-input/install/offering').attributes['id']
      end
    rescue Errno::ENOENT => e
      raise(e.message)
    end
    resp
  end

  def create
    if resource[:response]
      cmd_options = "input #{resource[:response]}"
    elsif resource[:user] == 'root'
      cmd_options =  "install #{resource[:package]}_#{resource[:version]}"
      cmd_options << " #{resource[:jdk_package_name]}_#{resource[:jdk_package_version]}" unless resource[:jdk_package_name].nil?
      cmd_options << " -repositories #{resource[:repository]} -installationDirectory #{resource[:target]}"
    else
      cmd_options =  "install #{resource[:package]}_#{resource[:version]}"
      cmd_options << " #{resource[:jdk_package_name]}_#{resource[:jdk_package_version]}" unless resource[:jdk_package_name].nil?
      cmd_options << " -repositories #{resource[:repository]} -installationDirectory #{resource[:target]} -accessRights nonAdmin"
    end
    cmd_options << ' -acceptLicense'
    cmd_options << " #{resource[:options]}" if resource[:options]

    stopprocs # stop related processes before we install
    imcl(cmd_options)
    # change owner

    FileUtils.chown_R(resource[:package_owner], resource[:package_group], resource[:target]) if resource.manage_ownership? && File.exist?(resource[:target])
  end

  def exists?
    @property_hash[:ensure] == :present
  end

  def destroy
    stopprocs
    cmd_options = "uninstall #{resource[:package]}_#{resource[:version]} -s -installationDirectory #{resource[:target]}"
    imcl(cmd_options)
  end

  # returns boolean true if the package and resource are the same
  # if a reponse file is given it returns true if the attributes
  # in the response file are the same
  def self.compare_package(package, resource)
    (package.target == resource[:target] && package.version == resource[:version] && package.package == resource[:package])
  end

  ## If the name matches, we consider the package to exist.
  ## The combination of id (package name), version, and path is what makes
  ## it unique.  You can have the same package/version installed to a
  ## different path. By prefetching here our exists? method becomes simple since
  def self.prefetch(resources)
    packages = instances(resources)
    return unless packages
    resources.keys.each do |name|
      if resources[name][:response]
        props = response_file_properties(resources[name][:response])
        # pre populate the things that were missing when the response file was parsed
        resources[name][:target] = props[:target]
        resources[name][:version] = props[:version]
        resources[name][:package] = props[:package]
      end
      provider = packages.find { |package| compare_package(package, resources[name]) }
      resources[name].provider = provider if provider
    end
  end

  def self.installed_packages(catalog)
    ## Determine if the specified package has been installed to the specified
    ## location by parsing IBM IM's "installed.xml" file.
    ## I *think* this is a pretty safe bet.  This seems to be a pretty hard-
    ## coded path for it on Linux and AIX.
    # returns a file handle by opening the registry file
    # easier to mock when extracted to method like this
    registry_file = nil
    catalog.keys.each do |name|
      registry_file = if installed_file(catalog[name][:user]).match(%r{^/var/ibm/}) || catalog[name][:user] == 'root'
                        '/var/ibm/InstallationManager/installRegistry.xml'
                      else
                        "#{find_user_home(catalog[name][:user])}/var/ibm/InstallationManager/installRegistry.xml"
                      end
    end
    registry = File.open(registry_file)
    doc = REXML::Document.new(registry)
    packages = []
    doc.elements.each('/installRegistry/profile') do |item|
      product_name = item.attributes['id'] # IBM Installation Manager
      path         = XPath.first(item, 'property[@name="installLocation"]/@value').value # /opt/Apps/WebSphere/was8.5/product/eclipse
      XPath.each(item, 'offering') do |offering|
        id = offering.attributes['id'] # com.ibm.cic.agent
        XPath.each(offering, 'version') do |package|
          version      = package.attributes['value'] # 1.6.2000.20130301_2248
          repository   = package.attributes['repoInfo'].split(',')[0].split('=')[1]
          packages << {
            product_name: product_name,
            path: path,
            package_id: id,
            version: version,
            repository: repository,
          }
        end
      end
      XPath.each(item, 'fix') do |fix|
        id = fix.attributes['id']
        XPath.each(fix, 'version') do |package|
          version      = package.attributes['value']
          repository   = package.attributes['repoInfo'].split(',')[0].split('=')[1]
          packages << {
            product_name: product_name,
            path: path,
            package_id: id,
            version: version,
            repository: repository,
          }
        end
      end
    end
    registry.close
    packages
  end

  def self.instances(catalog = nil)
    # get a list of installed packages
    installed_packages(catalog).map do |package|
      hash = {
        ensure: :present,
        package: package[:package_id],
        name: "#{package[:path]}:#{package[:package_id]}:#{package[:version]}",
        version: package[:version],
        target: package[:path],
        repository: package[:repository],
      }
      new(hash)
    end
  end
end
