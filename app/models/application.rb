class Application < ActiveRecord::Base
  belongs_to :user
  has_many :analytic_event_data, :dependent => :delete_all
  has_many :database_calls, :dependent => :delete_all
  has_many :transaction_data, :dependent => :delete_all
  has_many :transaction_sample_data, :dependent => :delete_all
  has_many :error_data, :dependent => :delete_all
  has_many :error_messages, :dependent => :delete_all
  has_many :database_types, :dependent => :delete_all
  has_many :transaction_endpoints, :dependent => :delete_all
  has_many :traces, :dependent => :delete_all
  has_many :layers, :dependent => :delete_all
  has_many :hosts, :dependent => :delete_all

  validates :name, :uniqueness => { :scope => :user_id }

  before_validation do |record|
    record.license_key ||= record.user.license_key
  end
end
