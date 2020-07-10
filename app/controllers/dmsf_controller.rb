# encoding: utf-8
# frozen_string_literal: true
#
# Redmine plugin for Document Management System "Features"
#
# Copyright © 2011    Vít Jonáš <vit.jonas@gmail.com>
# Copyright © 2012    Daniel Munn <dan.munn@munnster.co.uk>
# Copyright © 2011-20 Karel Pičman <karel.picman@kontron.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

class DmsfController < ApplicationController
  include RedmineDmsf::DmsfZip

  before_action :find_project
  before_action :authorize, except: [:expand_folder]
  before_action :find_folder, except: [:new, :create, :edit_root, :save_root, :add_email, :append_email,
                                          :autocomplete_for_user]
  before_action :find_parent, only: [:new, :create]
  before_action :permissions
  # Also try to lookup folder by title if this is an API call
  before_action :find_folder_by_title, only: [:show]
  before_action :get_query, only: [:expand_folder, :show, :trash]

  accept_api_auth :show, :create, :save, :delete

  helper :custom_fields
  helper :dmsf_folder_permissions
  helper :queries
  include QueriesHelper
  helper :dmsf_queries
  include DmsfQueriesHelper

  def permissions
    render_403 unless DmsfFolder.permissions?(@folder, false)
    true
  end

  def expand_folder
    @idnt = params[:idnt].present? ? params[:idnt].to_i + 1 : 0
    @query.dmsf_folder_id = @folder.id
    @query.deleted = false
    respond_to do |format|
      format.js { render action: 'query_rows' }
    end
  end

  def show
    @system_folder = @folder && @folder.system
    @locked_for_user = @folder && @folder.locked_for_user?
    @folder_manipulation_allowed = User.current.allowed_to?(:folder_manipulation, @project)
    @file_manipulation_allowed = User.current.allowed_to?(:file_manipulation, @project)
    @trash_enabled = @folder_manipulation_allowed && @file_manipulation_allowed
    @query.dmsf_folder_id = @folder ? @folder.id : nil
    @query.deleted = false
    if (@folder && @folder.deleted?) || (params[:folder_title].present? && !@folder)
      render_404
      return
    end
    if @query.valid?
      respond_to do |format|
        format.html {
          @dmsf_count = @query.dmsf_count
          @dmsf_pages = Paginator.new @dmsf_count, per_page_option, params['page']
          render layout: !request.xhr?
        }
        format.api {
          @offset, @limit = api_offset_and_limit
        }
        format.csv  {
          send_data query_to_csv(@query.dmsf_nodes, @query), type: 'text/csv; header=present', filename: 'dmsf.csv'
        }
      end
    else
      respond_to do |format|
        format.html {
          @dmsf_count = 0
          @dmsf_pages = Paginator.new @dmsf_count, per_page_option, params['page']
          render layout: !request.xhr?
        }
        format.any(:atom, :csv, :pdf) { head 422 }
        format.api { render_validation_errors(@query) }
      end
    end
  end

  def trash
    @folder_manipulation_allowed = User.current.allowed_to? :folder_manipulation, @project
    @file_manipulation_allowed = User.current.allowed_to? :file_manipulation, @project
    @file_delete_allowed = User.current.allowed_to? :file_delete, @project
    @query.deleted = true
    respond_to do |format|
      format.html {
        @dmsf_count = @query.dmsf_count
        @dmsf_pages = Paginator.new @dmsf_count, per_page_option, params['page']
        render layout: !request.xhr?
      }
    end
  end

  def download_email_entries
    # IE has got a tendency to cache files
    expires_in(0.year, 'must-revalidate' => true)
    send_file(
        params[:path],
        filename: 'Documents.zip',
        type: 'application/zip',
        disposition: 'attachment')
    rescue => e
      flash[:error] = e.message
  end

  def entries_operation
    # Download/Email
    if params[:ids].present?
      selected_folders = params[:ids].select{ |x| x =~ /folder-\d+/ }.map{ |x| $1.to_i if x =~ /folder-(\d+)/ }
      selected_files = params[:ids].select{ |x| x =~ /file-\d+/ }.map{ |x| $1.to_i if x =~ /file-(\d+)/ }
      selected_dir_links = params[:ids].select{ |x| x =~ /folder-link-\d+/ }.map{ |x| $1.to_i if x =~ /folder-link-(\d+)/ }
      selected_file_links = params[:ids].select{ |x| x =~ /file-link-\d+/ }.map{ |x| $1.to_i if x =~ /file-link-(\d+)/ }
      selected_url_links = params[:ids].select{ |x| x =~ /url-link-\d+/ }.map{ |x| $1.to_i if x =~ /url-link-(\d+)/ }
    else
      selected_folders = []
      selected_files = []
      selected_dir_links = []
      selected_file_links = []
      selected_url_links = []
    end

    if selected_folders.blank? && selected_files.blank? &&
      selected_dir_links.blank? && selected_file_links.blank? &&
      selected_url_links.blank?
      flash[:warning] = l(:warning_no_entries_selected)
      redirect_to :back
      return
    end

    if selected_dir_links.present? &&
      (params[:email_entries].present? || params[:download_entries].present?)
        selected_folders = DmsfLink.where(id: selected_dir_links).pluck(:target_id) | selected_folders
    end

    if selected_file_links.present? &&
      (params[:email_entries].present? || params[:download_entries].present?)
        selected_files = DmsfLink.where(id: selected_file_links).pluck(:target_id) | selected_files
    end

    begin
      if params[:email_entries].present?
        email_entries(selected_folders, selected_files)
      elsif params[:restore_entries].present?
        restore_entries(selected_folders, selected_files, selected_dir_links, selected_file_links, selected_url_links)
        redirect_to :back
      elsif params[:delete_entries].present?
        delete_entries(selected_folders, selected_files, selected_dir_links, selected_file_links, selected_url_links, false)
        redirect_to :back
      elsif params[:destroy_entries].present?
        delete_entries(selected_folders, selected_files, selected_dir_links, selected_file_links, selected_url_links, true)
        redirect_to :back
      else
        download_entries(selected_folders, selected_files)
      end
    rescue FileNotFound
      render_404
    rescue DmsfAccessError
      render_403
    rescue StandardError => e
      flash[:error] = e.message
      Rails.logger.error e.message
      return redirect_back(fallback_location: dmsf_folder_path(id: @project, folder_id: @folder))
    end
  end

  def tag_changed
    # Tag filter
    if params[:dmsf_folder]
      params[:dmsf_folder][:custom_field_values].each do |key, value|
        return redirect_to dmsf_folder_path id: @project, folder_id: @folder, custom_field_id: key, custom_value: value
      end
    end
    redirect_to :back
  end

  def entries_email
    if params[:email][:to].strip.blank?
      flash[:error] = l(:error_email_to_must_be_entered)
    else
      DmsfMailer.deliver_send_documents(@project, params[:email].permit!, User.current)
      if(File.exist?(params[:email][:zipped_content]))
        File.delete(params[:email][:zipped_content])
      else
        flash[:error] = l(:header_minimum_filesize)
      end
      flash[:notice] = l(:notice_email_sent, params[:email][:to])
    end
    redirect_to dmsf_folder_path(id: @project, folder_id: @folder)
  end

  def new
    @folder = DmsfFolder.new
    @pathfolder = @parent
    render action: 'edit'
  end

  def edit
    @parent = @folder.dmsf_folder
    @pathfolder = copy_folder(@folder)
    @force_file_unlock_allowed = User.current.allowed_to?(:force_file_unlock, @project)
    @redirect_to_folder_id = params[:redirect_to_folder_id]
  end

  def create
    @folder = DmsfFolder.new
    @folder.project = @project
    @folder.user = User.current
    saved = @folder.update_from_params(params)
    respond_to do |format|
      format.js
      format.api  {
        unless saved
          render_validation_errors(@folder)
        end
      }
      format.html {
        if saved
          flash[:notice] = l(:notice_folder_created)
          redirect_to dmsf_folder_path(id: @project, folder_id: @folder.dmsf_folder)
        else
          @pathfolder = @parent
          render action: 'edit'
        end
      }
    end

  end

  def save
    unless params[:dmsf_folder]
      redirect_to dmsf_folder_path(id: @project, folder_id: @folder)
      return
    end
    @pathfolder = copy_folder(@folder)
    saved = @folder.update_from_params(params)
    respond_to do |format|
      format.api {
        unless saved
          render_validation_errors(@folder)
        end
      }
      format.html {
        if saved
          flash[:notice] = l(:notice_folder_details_were_saved)
          redirect_to_folder_id = params[:dmsf_folder][:redirect_to_folder_id]
          redirect_to_folder_id = @folder.dmsf_folder.id if(@folder.dmsf_folder && redirect_to_folder_id.blank?)
          redirect_to dmsf_folder_path(id: @project, folder_id: redirect_to_folder_id)
        else
          render action: 'edit'
        end
      }
    end
  end

  def delete
    commit = params[:commit] == 'yes'
    result = @folder.delete(commit)
    if result
      flash[:notice] = l(:notice_folder_deleted)
    else
      flash[:error] = @folder.errors.full_messages.to_sentence
    end
    respond_to do |format|
      format.html do
        if commit
          redirect_to :back
        else
          redirect_to dmsf_folder_path(id: @project, folder_id: @folder.dmsf_folder)
        end
      end
      format.api { result ? render_api_ok : render_validation_errors(@folder) }
    end
  end

  def restore
    if @folder.restore
      flash[:notice] = l(:notice_dmsf_folder_restored)
    else
      flash[:error] = @folder.errors.full_messages.to_sentence
    end
    redirect_to :back
  end

  def edit_root
  end

  def save_root
    if params[:project]
      @project.dmsf_description = params[:project][:dmsf_description]
      if @project.save
        flash[:notice] = l(:notice_folder_details_were_saved)
      else
        flash[:error] = @project.errors.full_messages.to_sentence
      end
    end
    redirect_to dmsf_folder_path(id: @project)
  end

  def notify_activate
    if (@folder && @folder.notification) || (@folder.nil? && @project.dmsf_notification)
      flash[:warning] = l(:warning_folder_notifications_already_activated)
    else
      if @folder
        @folder.notify_activate
      else
        @project.dmsf_notification = true
        @project.save!
      end
      flash[:notice] = l(:notice_folder_notifications_activated)
    end
    redirect_to :back
  end

  def notify_deactivate
    if (@folder && !@folder.notification) || (@folder.nil? && !@project.dmsf_notification)
      flash[:warning] = l(:warning_folder_notifications_already_deactivated)
    else
      if @folder
        @folder.notify_deactivate
      else
        @project.dmsf_notification = nil
        @project.save!
      end
      flash[:notice] = l(:notice_folder_notifications_deactivated)
    end
    redirect_to :back
  end

  def lock
    if @folder.nil?
      flash[:warning] = l(:warning_foler_unlockable)
    elsif @folder.locked?
      flash[:warning] = l(:warning_folder_already_locked)
    else
      @folder.lock!
      flash[:notice] = l(:notice_folder_locked)
    end
      redirect_to :back
  end

  def unlock
    if @folder.nil?
      flash[:warning] = l(:warning_foler_unlockable)
    elsif !@folder.locked?
      flash[:warning] = l(:warning_folder_not_locked)
    else
      if @folder.locks[0].user == User.current || User.current.allowed_to?(:force_file_unlock, @project)
        @folder.unlock!
        flash[:notice] = l(:notice_folder_unlocked)
      else
        flash[:error] = l(:error_only_user_that_locked_folder_can_unlock_it)
      end
    end
     redirect_to :back
  end

  def add_email
    @principals = users_for_new_users
  end

  def append_email
    @principals = Principal.where(id: params[:user_ids]).to_a
    head :success if @principals.blank?
  end

  def autocomplete_for_user
    @principals = users_for_new_users
    respond_to do |format|
      format.js
    end
  end

  # Move the dragged object to the given destination
  def drop
    result = false
    if params[:dmsf_folder].present? && params[:dmsf_folder][:drag_id].present? && params[:dmsf_folder][:drop_id].present?
      if params[:dmsf_folder][:drag_id] =~ /(.+)-(\d+)/
        type = $1
        id = $2
        if params[:dmsf_folder][:drop_id] =~ /^folder.*-(\d+)/
          case type
          when 'file'
            dmsf_file = DmsfFile.find_by(id: id)
            dmsf_folder = DmsfFolder.find_by(id: $1)
            if dmsf_file && dmsf_folder
              result = dmsf_file.move_to(dmsf_file.project, dmsf_folder)
            end
          when 'folder'
            dmsf_folder = DmsfFolder.find_by(id: id)
            if dmsf_folder
              dmsf_folder.dmsf_folder_id = $1
              result = dmsf_folder.save
            end
          when 'file-link', 'folder-link', 'url-link'
            dmsf_link = DmsfLink.find_by(id: id)
            if dmsf_link
              dmsf_link.dmsf_folder_id = $1
              result = dmsf_link.save
            end
          end
        end
      end
    end
    respond_to do |format|
      if result
        format.js { head 200 }
      else
        format.js { head 422 }
      end
    end
  end

  private

  def users_for_new_users
    User.active.visible.member_of(@project).like(params[:q]).order(:type, :lastname).to_a
  end

  def email_entries(selected_folders, selected_files)
    raise DmsfAccessError unless User.current.allowed_to?(:email_documents, @project)
    zip = Zip.new
    zip_entries(zip, selected_folders, selected_files)
    zipped_content = zip.finish

    max_filesize = Setting.plugin_redmine_dmsf['dmsf_max_email_filesize'].to_f
    if max_filesize > 0 && File.size(zipped_content) > max_filesize * 1048576
      raise EmailMaxFileSize
    end

    zip.files.each do |f|
      audit = DmsfFileRevisionAccess.new
      audit.user = User.current
      audit.dmsf_file_revision = f.last_revision
      audit.action = DmsfFileRevisionAccess::EmailAction
      audit.save!
    end

    @email_params = {
      zipped_content: zipped_content,
      folders: selected_folders,
      files: selected_files,
      subject: "#{@project.name} #{l(:label_dmsf_file_plural).downcase}",
      from: Setting.plugin_redmine_dmsf['dmsf_documents_email_from'].presence ||
        "#{User.current.name} <#{User.current.mail}>",
      reply_to: Setting.plugin_redmine_dmsf['dmsf_documents_email_reply_to']
    }
    render action: 'email_entries'
  rescue Exception
    raise
  ensure
    zip.close if zip
  end

  def download_entries(selected_folders, selected_files)
    zip = Zip.new
    zip_entries(zip, selected_folders, selected_files)
    zip.files.each do |f|
      audit = DmsfFileRevisionAccess.new
      audit.user = User.current
      audit.dmsf_file_revision = f.last_revision
      audit.action = DmsfFileRevisionAccess::DownloadAction
      audit.save!
    end
    send_file(zip.finish,
      filename: filename_for_content_disposition("#{@project.name}-#{DateTime.current.strftime('%y%m%d%H%M%S')}.zip"),
      type: 'application/zip',
      disposition: 'attachment')
  rescue StandardError
    raise
  ensure
    zip.close if zip
  end

  def zip_entries(zip, selected_folders, selected_files)
    member = Member.find_by(user_id: User.current.id, project_id: @project.id)
    selected_folders.each do |selected_folder_id|
      folder = DmsfFolder.visible.find_by(id: selected_folder_id)
      if folder
        zip.add_folder(folder, member, (folder.dmsf_folder.dmsf_path_str if folder.dmsf_folder))
      else
        raise FileNotFound
      end
    end
    selected_files.each do |selected_file_id|
      file = DmsfFile.visible.find_by(id: selected_file_id)
      unless file && file.last_revision && File.exist?(file.last_revision.disk_file)
        raise FileNotFound
      end
      unless (file.project == @project) || User.current.allowed_to?(:view_dmsf_files, file.project)
        raise DmsfAccessError
      end
      zip.add_file(file, member, (file.dmsf_folder.dmsf_path_str if file.dmsf_folder))
    end
    max_files = Setting.plugin_redmine_dmsf['dmsf_max_file_download'].to_i
    if max_files > 0 && zip.files.length > max_files
      raise ZipMaxFilesError
    end
    zip
  end

  def restore_entries(selected_folders, selected_files, selected_dir_links, selected_file_links, selected_url_links)
    # Folders
    selected_folders.each do |id|
      folder = DmsfFolder.find_by(id: id)
      if folder
        unless folder.restore
          flash[:error] = folder.errors.full_messages.to_sentence
        end
      else
        raise FileNotFound
      end
    end
    # Files
    selected_files.each do |id|
      file = DmsfFile.find_by(id: id)
      if file
        unless file.restore
          flash[:error] = file.errors.full_messages.to_sentence
        end
      else
        raise FileNotFound
      end
    end
    # Links
    (selected_dir_links + selected_file_links + selected_url_links).each do |id|
      link = DmsfLink.find_by(id: id)
      if link
        unless link.restore
          flash[:error] = link.errors.full_messages.to_sentence
        end
      else
        raise FileNotFound
      end
    end
  end

  def delete_entries(selected_folders, selected_files, selected_dir_links, selected_file_links, selected_url_links, commit)
    # Folders
    selected_folders.each do |id|
      raise DmsfAccessError unless User.current.allowed_to?(:folder_manipulation, @project)
      folder = DmsfFolder.find_by(id: id)
      if folder
        unless folder.delete commit
          flash[:error] = folder.errors.full_messages.to_sentence
          return
        end
      elsif !commit
        raise FileNotFound
      end
    end
    # Files
    deleted_files = []
    not_deleted_files = []
    selected_files.each do |id|
      raise DmsfAccessError unless User.current.allowed_to?(:file_delete, @project)
      file = DmsfFile.find_by(id: id)
      if file
        if file.delete(commit)
          deleted_files << file unless commit
        else
          not_deleted_files << file
        end
      elsif !commit
        raise FileNotFound
      end
    end
    # Activities
    unless deleted_files.empty?
      begin
        recipients = DmsfMailer.deliver_files_deleted(@project, deleted_files)
        if Setting.plugin_redmine_dmsf['dmsf_display_notified_recipients']
          if recipients.any?
            to = recipients.collect{ |r| r.name }.first(DMSF_MAX_NOTIFICATION_RECEIVERS_INFO).join(', ')
            to << ((recipients.count > DMSF_MAX_NOTIFICATION_RECEIVERS_INFO) ? ',...' : '.')
            flash[:warning] = l(:warning_email_notifications, to: to)
          end
        end
      rescue => e
        Rails.logger.error "Could not send email notifications: #{e.message}"
      end
    end
    unless not_deleted_files.empty?
      flash[:warning] = l(:warning_some_entries_were_not_deleted, entries: not_deleted_files.map{ |f| f.title }.
          join(', '))
    end
    # Links
    selected_dir_links.each do |id|
      raise DmsfAccessError unless User.current.allowed_to?(:folder_manipulation, @project)
      link = DmsfLink.find_by(id: id)
      link.delete commit if link
    end
    (selected_file_links + selected_url_links).each do |id|
      raise DmsfAccessError unless User.current.allowed_to?(:file_delete, @project)
      link = DmsfLink.find_by(id: id)
      link.delete commit if link
    end
    if flash[:error].blank? && flash[:warning].blank?
      flash[:notice] = l(:notice_entries_deleted)
    end
  end

  def find_folder
    @folder = DmsfFolder.find(params[:folder_id]) if params[:folder_id].present?
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def find_folder_by_title
    if api_request? && !@folder && params[:folder_title].present?
      @folder = DmsfFolder.find_by(title: params[:folder_title], project_id: @project.id)
      render_404 unless @folder
    end
  end

  def find_parent
    @parent = DmsfFolder.visible.find params[:parent_id] if params[:parent_id].present?
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def copy_folder(folder)
    copy = folder.clone
    copy.id = folder.id
    copy
  end

  def get_query
    if Redmine::Plugin.installed?(:easy_extensions)
      @query = retrieve_query_without_easy_extensions(DmsfQuery, true)
    else
      @query = retrieve_query(DmsfQuery, true)
    end
  end

end
