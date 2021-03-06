class ApplicationController < ActionController::Base
  # Prevent CSRF attacks by raising an exception.
  # For APIs, you may want to use :null_session instead.
  protect_from_forgery with: :exception

  around_filter :use_time_zone
  before_filter :authenticate_user!

  before_action :set_current_organization
  before_action :authorize_current_organization!, :unless => :devise_controller?
  before_action :set_current_application
  before_action :set_current_page
  before_action :set_time_range

  layout :set_layout

  def set_current_organization
    if current_user
      if params[:organization_id]
        @current_organization ||= current_user.organizations.find_by_id(params[:organization_id])
      elsif session[:organization_id]
        @current_organization ||= current_user.organizations.find_by_id(session[:organization_id])
      end
    end
  end

  def authorize_current_organization!
    if @current_organization.nil?
      redirect_to organizations_path
    end
  end

  def set_current_application
    if current_user && @current_organization
      if params[:application_id]
        @current_application ||= @current_organization.applications.find_by_id(params[:application_id])
      elsif session[:application_id]
        @current_application ||= @current_organization.applications.find_by_id(session[:application_id])
      end
    end
  end

  def set_current_page
    @current_page = {
      "#{self.class}" => "active",
      "#{self.class}##{action_name}" => "active"
    }
  end

  def set_layout
    if current_user
      "application"
    else
      "public"
    end
  end

  def use_time_zone(&block)
    Time.use_zone('Eastern Time (US & Canada)', &block)
  end

  def set_time_range
    @time_range, @period = Reporter.time_range(params)
  end
end
