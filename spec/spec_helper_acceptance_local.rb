# frozen_string_literal: true
require 'puppet_litmus'
require 'tempfile'
require 'pry'

include PuppetLitmus

def create_remote_file(name, full_name, file_content)
  Tempfile.open name do |tempfile|
            File.open(tempfile.path, 'w') {|file| file.puts file_content }
            bolt_upload_file(tempfile.path, full_name)
  end
end

def inventory_hash
  @inventory_hash ||= inventory_hash_from_inventory_file
end

def target_roles(roles)
  # rubocop:disable Style/MultilineBlockChain
  inventory_hash['groups'].map { |group|
    group['targets'].map { |node|
      { name: node['uri'], role: node['vars']['role'] } if roles.include? node['vars']['role']
    }.reject { |val| val.nil? }
  }.flatten
  # rubocop:enable Style/MultilineBlockChain
end

def fetch_platform_by_node(uri)
  # rubocop:disable Style/MultilineBlockChain
  inventory_hash['groups'].map { |group|
    group['targets'].map { |node|
      if node['uri'] == uri
        return node['facts']['platform']
      else
        return nil
      end
    }
  }
  # rubocop:enable Style/MultilineBlockChain
end

def fetch_ip_hostname_by_role(role)
   #Fetch hostname and  ip adress for each node
   ipaddr = target_roles(role)[0][:name]
   platform = fetch_platform_by_node(ipaddr)
   ENV['TARGET_HOST'] = target_roles(role)[0][:name]
   hostname = run_shell('hostname').stdout.strip
   if os[:family] == 'redhat'
     int_ipaddr = run_shell("ip route get 8.8.8.8 | awk '{print $7; exit}'").stdout.strip
   else
     int_ipaddr = run_shell("ip route get 8.8.8.8 | awk '{print $NF; exit}'").stdout.strip
   end
   return hostname, ipaddr, int_ipaddr
end

def change_target_host(role)
  @orig_target_host = ENV['TARGET_HOST']
  ENV['TARGET_HOST'] = target_roles(role)[0][:name]
end

def reset_target_host
  ENV['TARGET_HOST'] = @orig_target_host
end

def configure_puppet_server(master, controller, worker)
  # Configure the puppet server
  ENV['TARGET_HOST'] = target_roles('master')[0][:name]
  run_bolt_task('puppet_conf', 'action' => 'set', 'section' => 'master', 'setting' => 'dns_alt_names', 'value' => "#{master},puppet")
  run_bolt_task('puppet_conf', 'action' => 'set', 'section' => 'main', 'setting' => 'server', 'value' => master)
  run_bolt_task('puppet_conf', 'action' => 'set', 'section' => 'main', 'setting' => 'certname', 'value' => master)
  run_bolt_task('puppet_conf', 'action' => 'set', 'section' => 'main', 'setting' => 'environment', 'value' => 'production')
  run_bolt_task('puppet_conf', 'action' => 'set', 'section' => 'main', 'setting' => 'runinterval', 'value' => '1h')
  run_shell('systemctl start puppetserver')
  run_shell('systemctl start puppetserver')
  # Configure the puppet agents
  configure_puppet_agent('controller', master, controller)
  puppet_cert_sign(controller)
  configure_puppet_agent('worker', master, worker)
  puppet_cert_sign(worker)
  # Create site.pp
  site_pp = <<-EOS
  node 'kube-master' {
    class {'kubernetes':
    controller => true,
  }
  node 'kube-node-01' {
    class {'kubernetes':
    controller => true,
  }
  node 'kube-node-02'  {
    class {'kubernetes':
    worker => true,
  }
  EOS
  ENV['TARGET_HOST'] = target_roles('master')[0][:name]
  environment_base_path = run_shell('puppet config print environmentpath').stdout.rstrip
  prod_env_site_pp_path = File.join(environment_base_path, 'production', 'manifests')
  create_remote_file("site.pp", prod_env_site_pp_path, site_pp)
end

def configure_puppet_agent(role, master, agent)
  # Configure the puppet agents
  ENV['TARGET_HOST'] = target_roles(role)[0][:name]
  run_bolt_task('puppet_conf', 'action' => 'set', 'section' => 'main', 'setting' => 'server', 'value' => master)
  run_bolt_task('puppet_conf', 'action' => 'set', 'section' => 'main', 'setting' => 'certname', 'value' => agent)
  run_bolt_task('puppet_conf', 'action' => 'set', 'section' => 'main', 'setting' => 'environment', 'value' => 'production')
  run_bolt_task('puppet_conf', 'action' => 'set', 'section' => 'main', 'setting' => 'runinterval', 'value' => '1h')
  run_shell('/opt/puppetlabs/bin/puppet resource service puppet ensure=running enable=true')
  run_shell("puppet agent --test", expect_failures: true)
end

def puppet_cert_sign(agent)
  # Sign the certs
  ENV['TARGET_HOST'] = target_roles('master')[0][:name]
  run_shell("puppetserver ca sign --certname #{agent}", expect_failures: true)
  run_shell("puppet agent --test", expect_failures: true)
end

RSpec.configure do |c|
  c.before :suite do
    # Fetch hostname and  ip adress for each node
    hostname1, ipaddr1, int_ipaddr1 =  fetch_ip_hostname_by_role('master')
    hostname2, ipaddr2, int_ipaddr2 =  fetch_ip_hostname_by_role('controller')
    hostname3, ipaddr3, int_ipaddr3 =  fetch_ip_hostname_by_role('worker')
    if c.filter.rules.key? :integration
      ENV['TARGET_HOST'] = target_roles('master')[0][:name]
      hosts_file = <<-EOS
      #{ipaddr1} #{hostname1}
      #{ipaddr2} #{hostname2}
      #{ipaddr3} #{hostname3}
      #{int_ipaddr1} #{hostname1}
      #{int_ipaddr2} #{hostname2}
      #{int_ipaddr3} #{hostname3}
            EOS
      create_remote_file("hosts","/etc/hosts", hosts_file)
      configure_puppet_server(hostname1, hostname2, hostname3)
    else
      c.filter_run_excluding :integration
    end

    family = fetch_platform_by_node(ENV['TARGET_HOST'])

    puts "Running acceptance test on #{hostname1} with address #{ipaddr1} and OS #{family}"

    run_shell('puppet module install puppetlabs-stdlib')
    run_shell('puppet module install puppetlabs-apt')
    run_shell('puppet module install stahnma-epel')
    run_shell('puppet module install maestrodev-wget')
    run_shell('puppet module install puppetlabs-translate')
    run_shell('puppet module install puppet-archive')
    run_shell('puppet module install herculesteam-augeasproviders_sysctl')
    run_shell('puppet module install herculesteam-augeasproviders_core')
    run_shell('puppet module install camptocamp-kmod')
    run_shell('puppet module install puppetlabs-docker')
    run_shell('puppet module install puppetlabs-helm')
    run_shell('puppet module install puppetlabs-rook --ignore-dependencies')

hosts_file = <<-EOS
127.0.0.1 localhost #{hostname1} kubernetes kube-master
#{ipaddr1} #{hostname1}
#{ipaddr1} kube-master
#{ipaddr2} kube-node-01
#{ipaddr3} kube-node-02
#{int_ipaddr1} #{hostname1}
#{int_ipaddr1} kube-master
#{int_ipaddr2} kube-node-01
#{int_ipaddr3} kube-node-02
      EOS

      nginx = <<-EOS
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-nginx
spec:
  selector:
    matchLabels:
      run: my-nginx
  replicas: 2
  template:
    metadata:
      labels:
        run: my-nginx
    spec:
      containers:
      - name: my-nginx
        image: nginx
        ports:
        - containerPort: 9880
---
apiVersion: v1
kind: Service
metadata:
  name: my-nginx
  labels:
    run: my-nginx
spec:
  clusterIP: 10.96.188.5
  ports:
  - port: 80
    protocol: TCP
  selector:
    run: my-nginx
EOS

      hiera = <<-EOS
version: 5
defaults:
  datadir: /etc/puppetlabs/code/environments/production/hieradata
  data_hash: yaml_data
hierarchy:
  - name: "Per-node data (yaml version)"
    path: "nodes/%{trusted.certname}.yaml" # Add file extension.
    # Omitting datadir and data_hash to use defaults.
  - name: "Other YAML hierarchy levels"
    paths: # Can specify an array of paths instead of one.
      - "location/%{facts.whereami}/%{facts.group}.yaml"
      - "groups/%{facts.group}.yaml"
      - "os/%{facts.os.family}.yaml"
      - "#{family.capitalize}.yaml"
      - "#{hostname1}.yaml"
      - "Redhat.yaml"
      - "common.yaml"
EOS
      k8repo = <<-EOS
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOS
  pp = <<-PUPPETCODE
    # needed by tests
    package { 'curl':
      ensure   => 'latest',
    }
    package { 'git':
      ensure   => 'latest',
    }
  PUPPETCODE
  apply_manifest(pp)
  if family =~ /debian|ubuntu-1604-lts/
    runtime = 'cri_containerd'
    cni = 'weave'
    run_shell('apt-get update && apt-get install -y apt-transport-https')
    run_shell('curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -')
    run_shell('echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee -a /etc/apt/sources.list.d/kubernetes.list')
    run_shell('apt-get update')
    run_shell('apt-get install -y kubectl')
    run_shell('sudo apt install docker.io -y')

    if family =~ /ubuntu-1604-lts/
      run_shell('sudo ufw disable')
    else
      # Workaround for debian as the strech repositories do not have updated kubernetes packages
      run_shell('echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" >> /etc/apt/sources.list.d/kube-xenial.list')
      run_shell('/sbin/iptables -F')
    end
  end
  if family =~ /redhat|centos/
    runtime = 'docker'
    cni = 'flannel'
    run_shell('gpg --keyserver hkp://keys.gnupg.net --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3 7D2BAF1CF37B13E2069D6956105BD0E739499BDB')
    run_shell('setenforce 0 || true')
    run_shell('swapoff -a')
    run_shell('systemctl stop firewalld && systemctl disable firewalld')
    run_shell('yum install -y yum-utils device-mapper-persistent-data lvm2')
    run_shell('yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo')
    run_shell('yum update -y')
    run_shell('yum install -y docker-ce-18.06.3.ce-3.el7')
    run_shell("usermod -aG docker $(whoami)")
    run_shell('systemctl start docker.service')
    create_remote_file("k8repo","/etc/yum.repos.d/kubernetes.repo", k8repo)
    run_shell('yum install -y kubectl')
  end

  run_shell('docker build -t kubetool:latest /etc/puppetlabs/code/environments/production/modules/kubernetes/tooling')
  run_shell("docker run --rm -v $(pwd)/hieradata:/mnt -e OS=#{family} -e VERSION=1.16.6 -e CONTAINER_RUNTIME=#{runtime} -e CNI_PROVIDER=#{cni} -e ETCD_INITIAL_CLUSTER=#{hostname1}:#{int_ipaddr1} -e ETCD_IP=#{int_ipaddr1} -e ETCD_PEERS=[#{int_ipaddr1},#{int_ipaddr2},#{int_ipaddr3}] -e KUBE_API_ADVERTISE_ADDRESS=#{int_ipaddr1} -e INSTALL_DASHBOARD=true kubetool:latest")
  create_remote_file("hosts","/etc/hosts", hosts_file)
  create_remote_file("nginx","/tmp/nginx.yml", nginx)
  create_remote_file("hiera","/etc/puppetlabs/puppet/hiera.yaml", hiera)
  create_remote_file("hiera_prod","/etc/puppetlabs/code/environments/production/hiera.yaml", hiera)
  run_shell('mkdir -p /etc/puppetlabs/code/environments/production/hieradata')
  run_shell("cp $HOME/hieradata/*.yaml /etc/puppetlabs/code/environments/production/hieradata/")

  if family =~ /debian|ubuntu-1604-lts/
    run_shell("echo 'kubernetes::cni_network_provider: https://cloud.weave.works/k8s/net?k8s-version=1.16.6' >> /etc/puppetlabs/code/environments/production/hieradata/#{family.capitalize}.yaml")
  end

  if family =~ /redhat|centos/
    run_shell("echo 'kubernetes::cni_network_provider: https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml' >> /etc/puppetlabs/code/environments/production/hieradata/#{family.capitalize}.yaml")
  end

  run_shell("sed -i /cni_network_provider/d /etc/puppetlabs/code/environments/production/hieradata/#{family.capitalize}.yaml")
  run_shell("echo 'kubernetes::schedule_on_controller: true'  >> /etc/puppetlabs/code/environments/production/hieradata/#{family.capitalize}.yaml")
  run_shell("echo 'kubernetes::taint_master: false' >> /etc/puppetlabs/code/environments/production/hieradata/#{family.capitalize}.yaml")
  run_shell("export KUBECONFIG=\'/etc/kubernetes/admin.conf\'")

end
end
