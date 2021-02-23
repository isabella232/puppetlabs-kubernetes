# frozen_string_literal: true

require 'spec_helper_acceptance'
require 'json'

describe 'we are able to setup an master, controller and worker', :integration do
  before(:all) { change_target_host('master') }
  after(:all) { reset_target_host }
  it 'verify the setup' do
      run_shell('puppet agent --test')
  end
end
