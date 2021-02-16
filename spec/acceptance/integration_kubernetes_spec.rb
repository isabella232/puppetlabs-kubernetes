# frozen_string_literal: true

require 'spec_helper_acceptance'
require 'json'
require 'pry'

describe 'we are able to setup an master, controller and worker', :integration do
  context 'set up the master' do
    before(:all) { change_target_host('master') }
    after(:all) { reset_target_host }
    describe 'set up master' do
      pp = <<-MANIFEST
        class {'kubernetes':
          controller => true,
        }
      MANIFEST
      it 'sets up the master' do
        apply_manifest(pp)
      end
    end
  end
end
