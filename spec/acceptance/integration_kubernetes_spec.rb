# frozen_string_literal: true

require 'spec_helper_acceptance'
require 'json'

describe 'we are able to setup an master, controller and worker', :integration do
  context 'set up the master' do
    before(:all) { change_target_host('master') }
    after(:all) { reset_target_host }
    describe 'set up master' do
      it 'sets up the master' do
        run_shell('puppet agent --test')
      end
    end
  end
  context 'set up the worker1' do
    before(:all) { change_target_host('controller') }
    after(:all) { reset_target_host }
    describe 'set up worker' do
      it 'sets up the worker' do
        clear_certs('controller')
        run_shell('puppet agent --test')
      end
    end
  end
  context 'set up the worker2' do
    before(:all) { change_target_host('worker') }
    after(:all) { reset_target_host }
    describe 'set up worker' do
      it 'sets up the worker' do
        clear_certs('worker')
        run_shell('puppet agent --test')
      end
    end
  end
end
