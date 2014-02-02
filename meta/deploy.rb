#!/usr/bin/env ruby

require 'keychain'
require 'linodeapi'
require 'json'

STACKSCRIPT_ID = 8125
DISTRIBUTION_ID = 112
KERNEL_ID = 138
PV_GRUB_ID = 95

HOSTNAME = ARGV.first || fail('Please supply a hostname')

def jobs_running?(linode)
  jobs = API.linode.job.list(linodeid: linode)
  jobs.select { |job| job[:host_finish_dt] == '' }.length > 0
end

def wait_for_jobs(linode)
  while jobs_running? linode
    print '.'
    sleep 5
  end
  puts
end

api_key = Keychain.open('/Volumes/akerl-vault/archer.keychain')
api_key = api_key.generic_passwords.where(service: 'linode-api')
api_key = api_key.first.password

API = LinodeAPI::Raw.new(apikey: api_key)

linode = API.linode.list.find { |l| l[:label] == HOSTNAME }
linode = linode.fetch(:linodeid) { fail 'Linode not found' }

existing = {
  configs: API.linode.config.list(linodeid: linode),
  disks: API.linode.disk.list(linodeid: linode)
}

existing.each do |type, things|
  puts "#{type.capitalize}:"
  things.each { |thing| puts "    #{thing[:label]}" }
end
puts 'Hit enter to confirm deletion of those configs and disks'
STDIN.gets

API.linode.shutdown(linodeid: linode)
existing[:configs].each do |config|
  API.linode.config.delete(linodeid: linode, configid: config[:configid])
end
existing[:disks].each do |disk|
  API.linode.disk.delete(linodeid: linode, diskid: disk[:diskid])
end

wait_for_jobs linode

devices = [
  ['swap', 256, :swap],
  ['root', 512, :ext3],
  ['lvm', 40_960, :raw]
]

devices.map! do |name, size, type|
  disk = API.linode.disk.create(
    linodeid: linode,
    label: name,
    size: size,
    type: type
  )
  [name, disk[:diskid]]
end

devices = Hash[devices]

root_pw = (('a'..'z').to_a.shuffle[0, 20] + (1..9).to_a.shuffle[0, 5]).join
devices['maker'] = API.linode.disk.createfromstackscript(
  linodeid: linode,
  stackscriptid: STACKSCRIPT_ID,
  distributionid: DISTRIBUTION_ID,
  rootpass: root_pw,
  label: 'maker',
  size: 7424,
  stackscriptudfresponses: { name: HOSTNAME }.to_json
)[:diskid]

config = API.linode.config.create(
  kernelid: KERNEL_ID,
  disklist: devices.values_at('maker', 'swap', 'root', 'lvm').join(','),
  label: 'dock0',
  linodeid: linode
)[:configid]

API.linode.boot(linodeid: linode, configid: config)
sleep 2
wait_for_jobs linode

API.linode.config.update(
  linodeid: linode,
  configid: config,
  helper_depmod: false,
  helper_xen: false,
  helper_disableupdatedb: false,
  devtmpfs_automount: false,
  disklist: devices.values_at('root', 'swap', 'lvm').join(','),
  kernelid: PV_GRUB_ID
)

puts "Success! (root pw is #{root_pw})"