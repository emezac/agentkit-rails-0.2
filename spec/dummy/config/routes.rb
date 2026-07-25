# frozen_string_literal: true

Rails.application.routes.draw do
  mount Agentkit::Engine => "/agentkit"
end
