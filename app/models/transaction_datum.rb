class TransactionDatum < ActiveRecord::Base
  belongs_to :application
  belongs_to :host
  belongs_to :transaction_endpoint
  belongs_to :layer
end
