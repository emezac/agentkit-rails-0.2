# frozen_string_literal: true

module Agentkit
  # The host's user and account, for the columns every kernel table already
  # carries.
  #
  # 0.1 declared `belongs_to :user` on its records. 0.2 removed it to avoid
  # assuming the host's class names — but the columns stayed, so
  # `create!(user: someone)` became an UnknownAttributeError and every host
  # upgrading had to rewrite each call site to `user_id:`. That is a migration
  # tax for no benefit.
  #
  # Class names come from configuration and are resolved lazily by Rails, so an
  # app with no User model is unaffected until it actually touches the
  # association.
  module TenantAssociations
    extend ActiveSupport::Concern

    included do
      belongs_to :user, optional: true,
                        class_name: Agentkit.config.user_class.to_s,
                        inverse_of: false

      belongs_to :account, optional: true,
                           class_name: Agentkit.config.account_class.to_s,
                           inverse_of: false
    end
  end
end
