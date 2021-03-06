# Cookbook Name:: crowbar
# Recipe:: prepare-upgrade-scripts
#
# Copyright 2013-2016, SUSE LINUX Products GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# This recipe prepares various scripts usable for upgrading the node

# First part is for OS upgrade. When executed (at selected time), it
# 1. removes old repositories
# 2. adds correct new ones
# 3. runs zypper dup to upgrade the node

arch = node[:kernel][:machine]

old_repos = Provisioner::Repositories.get_repos(
  node[:platform], node[:platform_version], arch
)

target_platform, target_platform_version = node[:target_platform].split("-")
new_repos = Provisioner::Repositories.get_repos(
  target_platform, target_platform_version, arch
)

# Find out the location of the base system repository
provisioner_instance = CrowbarHelper.get_proposal_instance(node, "provisioner", "default")
provisioner = node_search_with_cache("roles:provisioner-server", provisioner_instance).first
admin_ip = Barclamp::Inventory.get_network_by_type(provisioner, "admin").address

web_port = provisioner[:provisioner][:web_port]
provisioner_web = "http://#{admin_ip}:#{web_port}"

web_path = "#{provisioner_web}/#{node[:platform]}-#{node[:platform_version]}/#{arch}"
old_install_url = "#{web_path}/install"

web_path = "#{provisioner_web}/#{node[:target_platform]}/#{arch}"
new_install_url = "#{web_path}/install"

# try to create an alias for new base repo from the original base repo
repo_alias = "SLES12-SP1-12.1-0"
doc = REXML::Document.new(`zypper --xmlout lr --details`)
doc.elements.each("stream/repo-list/repo") do |repo|
  repo_alias = repo.attributes["alias"] if repo.elements["url"].text == old_install_url
end

new_alias = repo_alias.gsub("SP1", "SP2").gsub(node[:platform_version], target_platform_version)

template "/usr/sbin/crowbar-upgrade-os.sh" do
  source "crowbar-upgrade-os.erb"
  mode "0755"
  owner "root"
  group "root"
  action :create
  variables(
    old_repos: old_repos,
    new_repos: new_repos,
    target_platform_version: target_platform_version,
    old_base_repo: old_install_url,
    new_base_repo: new_install_url,
    new_alias: new_alias
  )
end

# This script shuts down non-essential services on the nodes
# It leaves only database (so we can create a dump of it)
# and services necessary for managing network traffic of running instances.

# Find out now if we have HA setup and pass that info to the script
use_ha = node["run_list_map"].key? "pacemaker-cluster-member"
cluster_founder = use_ha && node["pacemaker"]["founder"]

template "/usr/sbin/crowbar-shutdown-services-before-upgrade.sh" do
  source "crowbar-shutdown-services-before-upgrade.sh.erb"
  mode "0755"
  owner "root"
  group "root"
  action :create
  variables(
    use_ha: use_ha,
    cluster_founder: cluster_founder
  )
end

cinder_controller = node["run_list_map"].key? "cinder-controller"

template "/usr/sbin/crowbar-delete-cinder-services-before-upgrade.sh" do
  source "crowbar-delete-cinder-services-before-upgrade.sh.erb"
  mode "0755"
  owner "root"
  group "root"
  action :create
  only_if { cinder_controller && (!use_ha || cluster_founder) }
end

# Find all ovs bridges that we manage to be able to reset their fail-mode
# in preparation for the OS upgrade
bridges_to_reset = []
Barclamp::Inventory.list_networks(node).each do |network|
  next unless network.add_ovs_bridge
  bridges_to_reset << network.bridge_name
end

# Following script executes all actions that are needed directly on the node
# directly before the OS upgrade is initiated.
template "/usr/sbin/crowbar-pre-upgrade.sh" do
  source "crowbar-pre-upgrade.sh.erb"
  mode "0755"
  owner "root"
  group "root"
  action :create
  variables(
    use_ha: use_ha,
    bridges_to_reset: bridges_to_reset
  )
end

template "/usr/sbin/crowbar-delete-pacemaker-resources.sh" do
  source "crowbar-delete-pacemaker-resources.sh.erb"
  mode "0755"
  owner "root"
  group "root"
  action :create
  variables(
    use_ha: use_ha
  )
end

template "/usr/sbin/crowbar-router-migration.sh" do
  source "crowbar-router-migration.sh.erb"
  mode "0755"
  owner "root"
  group "root"
  action :create
end

has_drbd = use_ha && node.fetch("drbd", {}).fetch("rsc", {}).any?

template "/usr/sbin/crowbar-post-upgrade.sh" do
  source "crowbar-post-upgrade.sh.erb"
  mode "0775"
  owner "root"
  group "root"
  action :create
  variables(
    use_ha: use_ha,
    has_drbd: has_drbd
  )
end

template "/usr/sbin/crowbar-chef-upgraded.sh" do
  source "crowbar-chef-upgraded.sh.erb"
  mode "0775"
  owner "root"
  group "root"
  action :create
end
