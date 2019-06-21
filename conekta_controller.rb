# -*- coding: utf-8 -*-
class ConektaController < ApplicationController
  include Projects::BackersHelper
  before_action :load_current_rate, only: [:payment]

  def payment
    return render_json_error if preparations_failed?
    # second rescue bloc to move out
    begin
      # too much nesting ins this hash
      attributes = {
        currency: Rails.application.secrets.currency_code,
        customer_info: {
          customer_id: customer.id
        },
        line_items: [{
          name: backer.id.to_s + "-" + backer.project.name.parameterize,
          unit_price: backer.value_in_cents("mxn"),
          quantity: 1,
          antifraud_info: {
            project_id: backer.project.id.to_s + "_" + backer.project.slug,
            starts_at: backer.project.publication_date.to_i,
            ends_at: backer.project.expires_at.to_i,
            target_amount: (backer.project.goal * 100).to_i
          }
        }],
        charges: [{
          payment_method: {
            type: "default"
          }
        }]
      }
      # we're creating an order but its called charge?
      charge = Conekta::Order.create(attributes)
      if charge.payment_status == "paid"
        # success scenario
        payment = charge.charges.first
        backer.update_attributes({
          transaction_id: charge.id,
          gross_amount: (payment.amount / 100.0),
          gross_amount_currency_id: payment.currency,
          fee_amount: localize_charge_fee(payment.fee/100.0, backer.project.currency),
          card_number: payment.payment_method.last4,
          card_brand: payment.payment_method.brand,
          card_name: payment.payment_method.name,
          card_issuer: payment.payment_method.issuer,
          expiration_month: payment.payment_method.exp_month,
          expiration_year: payment.payment_method.exp_year
        })
        backer.confirm!
        send_successful_back_emails(backer)
        result[:status] = "approved"
        result[:redirect] = success_conektum_path(backer)
      else
        #fail scenario
        backer.update_attributes transaction_id: charge.id, failure_code: charge.failure_code
        result[:status] = "declined"
        FondeadoraMailer.failed_card_back(backer).deliver_later!
      end
      #rescue  from earlier begin
    rescue Conekta::ErrorList => error_list
      # sets only last error in list.
      for error_detail in error_list.details do
        result[:status] = "declined"
        result[:message] = error_detail.message
      end
      # second rescue
    rescue Exception => e
      result[:status] = "declined"
      result[:message] = e.inspect
    end
    render json: result.to_json
  end

  private

  def preparations_failed?
    project.nil? ||
    backer.nil? ||
    backer.errors.any? ||
    customer.nil?
  end

  def render_json_error
    result[:status] = 'error'
    result[:message] =  @error || 'Something went wrong :('
    render json: result.to_json
  end

  def project
    @project ||= Project.friendly.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    @error = 'Project missing.'
    nil
  end

  def reward
    @reward ||= Reward.find(params[:reward_id])
  rescue ActiveRecord::RecordNotFound
    @error = 'Reward missing.'
    nil
  end

  def result
    @result ||= Hash.new
  end

  def backer
    @backer ||= create_backer
  rescue StandardError
    @error = backer.errors.full_messages.join(', ') if backer.errors.any?
    @error ||= 'Backer missing.'
    nil
  end

  def create_backer
    Backer.create(backer_params) do |backer|
      verify_recaptcha(model: backer, message: "Failed recaptcha.") if verify_recaptcha?
      backer.reward = reward if reward.present? && backer.value >= reward.minimum_value 
    end
  end

  def verify_recaptcha?
    Rails.env.production? && params["g-recaptcha-response"]
  end

  def backer_params
    {
      user: current_user,
      project: project,
      country: @visitor_country.alpha2,
      value: calculate_value.round(2),
      currency_value: params[:backing_amount],
      currency_code: @current_currency.iso_code,
      payment_method: 'Conekta',
      payment_token: params[:conektaTokenId]
    }
  end

  def calculate_value
    params[:backing_amount].to_f * Rails.cache.read(project.currency.downcase).to_f / @current_rate
  end

  def customer
    @customer ||= create_customer
  rescue StandardError
    nil
  end

  def create_customer
    return nil if params[:conektaTokenId].nil?
    Conekta::Customer.create(customer_params)
  end

  def customer_params
    {
      name: current_user.name,
      email: current_user.email,
      payment_sources: payment_sources
    }
  end

  def payment_sources
    [{
      type: 'card',
      token_id: params[:conektaTokenId]
    }]
  end

  def load_current_rate
    # split
    currency = session["currency"]
    if currency
      @current_rate = Rails.cache.read(currency.downcase).to_f
      @current_currency = 1.to_money(currency).currency
    else
      @current_rate = @mxn_rate
      @current_currency =  1.to_money("mxn").currency
    end
  end
end
