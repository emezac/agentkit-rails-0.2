# frozen_string_literal: true

require "spec_helper"

# A spent daily quota is not a transient rate limit.
#
# Both carry the words "rate limit", and that is how a real outage happened: the
# message `Rate limit exceeded: free-models-per-day` matched the transient
# pattern, so the caller retried the same exhausted provider three times with
# backoff. Every attempt failed. The fallback chain never advanced, because
# fallback only fires on PermanentError — so an application with a perfectly good
# second provider configured stayed dead until the quota reset at midnight.
#
# Waiting half a second does not refill a daily allowance.
RSpec.describe Agentkit::LLM::Adapters::Base do
  subject(:adapter) { described_class.new }

  def clase_de(mensaje)
    adapter.classify(StandardError.new(mensaje))
  end

  describe "cuotas agotadas: permanentes, para que la cadena avance" do
    [
      "Rate limit exceeded: free-models-per-day. Add 10 credits to unlock 1000 free model requests per day",
      "You have exceeded your requests-per-month allowance",
      "Daily limit reached for this model",
      "Daily quota exhausted",
      "quota exceeded for this project",
      "insufficient_quota: check your plan and billing details",
      "Your wallet has no balance to cover the model 'qwen'",
      "insufficient funds",
      "insufficient credit for this request",
      "Billing hard limit has been reached"
    ].each do |mensaje|
      it "#{mensaje[0, 44]}… es permanente" do
        expect(clase_de(mensaje)).to eq(Agentkit::PermanentError)
      end
    end
  end

  describe "límites por minuto: siguen siendo transitorios" do
    # Estos sí se arreglan esperando, y bajar a un modelo peor por un pico de
    # tráfico sería peor que reintentar.
    [
      "Rate limit exceeded: 20 requests per minute",
      "429 Too Many Requests",
      "Request timed out",
      "upstream connection error",
      "The service is overloaded, please try again",
      "temporarily unavailable",
      "503 Service Unavailable"
    ].each do |mensaje|
      it "#{mensaje[0, 44]}… es transitorio" do
        expect(clase_de(mensaje)).to eq(Agentkit::TransientError)
      end
    end
  end

  # El caso que motivó todo esto, escrito literal.
  it "el mensaje exacto de OpenRouter que dejó una app muerta hasta medianoche" do
    real = "Rate limit exceeded: free-models-per-day. " \
           "Add 10 credits to unlock 1000 free model requests per day"

    expect(clase_de(real)).to eq(Agentkit::PermanentError),
      "sigue siendo transitorio: se reintentará contra el proveedor agotado " \
      "y la cadena de fallback nunca va a avanzar"
  end

  it "lo que no reconoce sigue siendo permanente" do
    expect(clase_de("invalid api key")).to eq(Agentkit::PermanentError)
  end
end
