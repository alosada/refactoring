require 'rails_helper'

RSpec.describe ConektaController do

  before :each do
    @user = create(:user)
    @project = create(:project)
    @current_rate = 1.0
    @visitor_country = Country.new('MX')
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(@user)
  end

  describe 'POST payment' do
    it 'processes payment' do
      parameters = {
        backing_amount: '100.0',
        reward_id: '110902',
        conektaTokenId: 'tok_test_visa_4242',
        controller: 'conekta',
        action: 'payment',
        id: 'mexico-on-rails'
      }
      post :payment, parameters
      status = JSON.parse(response.body)['status']
      expect(status).to eq 'approved'
    end
    it 'processes payment but is declined' do
      parameters = {
        backing_amount: '100.0',
        reward_id: '110902',
        conektaTokenId: 'tok_test_card_declined',
        controller: 'conekta',
        action: 'payment',
        id: 'mexico-on-rails'
      }
      post :payment, parameters
      status = JSON.parse(response.body)['status']
      expect(status).to eq 'declined'
    end
  end
end

