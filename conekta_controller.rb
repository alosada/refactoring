# -*- coding: utf-8 -*-
class ConektaController < ApplicationController
  include Projects::BackersHelper
  before_action :load_current_rate, only: [:payment]

  def payment
    return render_json_error if preparations_failed?
    order_post_process(order)
    render json: result.to_json
  end

  private

  def render_json_error
    result[:status] ||= 'error'
    result[:message] =  @error || 'Something went wrong :('
    render json: result.to_json
  end

  def preparations_failed?
    project.nil? ||
    backer.nil? ||
    backer.errors.any? ||
    customer.nil? ||
    order.nil?
  end

  def project
    @project ||= Project.friendly.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    @error = 'Project missing.'
    nil
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

  def backer_params
    {
      user: current_user,
      project: project,
      country: @visitor_country.alpha2,
      value: calculate_backer_value.round(2),
      currency_value: params[:backing_amount],
      currency_code: @current_currency.iso_code,
      payment_method: 'Conekta',
      payment_token: params[:conektaTokenId]
    }
  end

  def calculate_backer_value
    params[:backing_amount].to_f * Rails.cache.read(project.currency.downcase).to_f / @current_rate
  end

  def verify_recaptcha?
    Rails.env.production? && params["g-recaptcha-response"]
  end
  
  def reward
    @reward ||= Reward.find(params[:reward_id])
  rescue ActiveRecord::RecordNotFound
    @error = 'Reward missing.'
    nil
  end

  # START CONEKTA METHODS -> more to wrapper.

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

  def order
    @order ||= create_order
  rescue StandardError => e
    nil
  end

  def create_order
    Conekta::Order.create(order_attributes)
  rescue Conekta::ErrorList => error_list
    result[:status] = "declined"
    result[:message] = error_list.details.map {|e| e.message}.join(', ')
    nil
  end

  def order_attributes
    {
      currency: Rails.application.secrets.currency_code,
      customer_info: { customer_id: customer.id },
      line_items: order_line_items,
      charges: order_charges
    }
  end

  def order_line_items
    [{
      name: backer.id.to_s + "-" + backer.project.name.parameterize,
      unit_price: backer.value_in_cents("mxn"),
      quantity: 1,
      antifraud_info: order_antifraud_info
    }]
  end

  def order_antifraud_info
    {
      project_id: backer.project.id.to_s + "_" + backer.project.slug,
      starts_at: backer.project.publication_date.to_i,
      ends_at: backer.project.expires_at.to_i,
      target_amount: (backer.project.goal * 100).to_i
    }
  end

  def order_charges
    [{
      payment_method: { type: "default"}
    }]
  end

  # END CONEKTA METHODS

  def result
    @result ||= Hash.new
  end

  def order_post_process(order)
    return paid_order_post_process if order.payment_status == "paid"
    failed_order_post_process
  end

  def paid_order_post_process
    backer.update_attributes(back_success_attributes)
    backer.confirm!
    send_successful_back_emails(backer)
    result[:status] = "approved"
    result[:redirect] = success_conektum_path(backer)
  end

  def back_success_attributes
    charge = order.charges.first
    {
      transaction_id: order.id,
      gross_amount: (charge.amount / 100.0),
      gross_amount_currency_id: charge.currency,
      fee_amount: localize_charge_fee(charge.fee/100.0, backer.project.currency),
      card_number: charge.payment_method.last4,
      card_brand: charge.payment_method.brand,
      card_name: charge.payment_method.name,
      card_issuer: charge.payment_method.issuer,
      expiration_month: charge.payment_method.exp_month,
      expiration_year: charge.payment_method.exp_year
    }
  end

  def failed_order_post_process
    backer.update_attributes transaction_id: order.id, failure_code: order.failure_code
    result[:status] = "declined"
    FondeadoraMailer.failed_card_back(backer).deliver_later!
  end

  def load_current_rate
    return currency_from_sessions if session["currency"]
    default_currency
  end

  def currency_from_sessions
    @current_rate = Rails.cache.read(session["currency"].downcase).to_f
    @current_currency = 1.to_money(session["currency"]).currency
  end

  def default_currency
    @current_rate = @mxn_rate
    @current_currency =  1.to_money("mxn").currency
  end
end
