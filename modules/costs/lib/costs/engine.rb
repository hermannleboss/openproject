#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) 2012-2020 the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2017 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
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
#
# See docs/COPYRIGHT.rdoc for more details.
#++

require 'open_project/plugins'

module Costs
  class Engine < ::Rails::Engine
    engine_name :costs

    include OpenProject::Plugins::ActsAsOpEngine

    register 'costs',
             author_url: 'https://www.openproject.com',
             bundled: true,
             settings: {
               default: { 'costs_currency' => 'EUR', 'costs_currency_format' => '%n %u' },
               partial: 'settings/costs',
               menu_item: :costs_setting
             },
             name: :project_module_costs do
      project_module :costs do
        permission :view_time_entries,
                   timelog: %i[index show],
                   time_entry_reports: [:report]

        permission :log_time,
                   { timelog: %i[new create edit update] },
                   require: :loggedin

        permission :edit_time_entries,
                   { timelog: %i[new create edit update destroy] },
                   require: :member

        permission :view_own_time_entries,
                   timelog: %i[index report]

        permission :edit_own_time_entries,
                   { timelog: %i[new create edit update destroy] },
                   require: :loggedin

        permission :manage_project_activities,
                   { 'projects/time_entry_activities': %i[update] },
                   require: :member
        permission :view_own_hourly_rate, {}
        permission :view_hourly_rates, {}

        permission :edit_own_hourly_rate, { hourly_rates: %i[set_rate edit update] },
                   require: :member
        permission :edit_hourly_rates, { hourly_rates: %i[set_rate edit update] },
                   require: :member
        permission :view_cost_rates, {} # cost item values

        permission :log_own_costs, { costlog: %i[new create] },
                   require: :loggedin
        permission :log_costs, { costlog: %i[new create] },
                   require: :member

        permission :edit_own_cost_entries, { costlog: %i[edit update destroy] },
                   require: :loggedin
        permission :edit_cost_entries, { costlog: %i[edit update destroy] },
                   require: :member

        permission :view_cost_entries, { budgets: %i[index show], costlog: [:index] }
        permission :view_own_cost_entries, { budgets: %i[index show], costlog: [:index] }
      end

      # Menu extensions
      menu :admin_menu,
           :cost_types,
           { controller: '/cost_types', action: 'index' },
           parent: :admin_costs,
           caption: :label_cost_type_plural
    end

    patches %i[Project User TimeEntry PermittedParams ProjectsController]
    patch_with_namespace :BasicData, :RoleSeeder
    patch_with_namespace :BasicData, :SettingSeeder
    patch_with_namespace :ActiveSupport, :NumberHelper, :NumberToCurrencyConverter

    add_tab_entry :user,
                  name: 'rates',
                  partial: 'users/rates',
                  path: ->(params) { tab_edit_user_path(params[:user], tab: :rates) },
                  label: :caption_rate_history

    add_api_path :cost_entry do |id|
      "#{root}/cost_entries/#{id}"
    end

    add_api_path :cost_entries_by_work_package do |id|
      "#{work_package(id)}/cost_entries"
    end

    add_api_path :summarized_work_package_costs_by_type do |id|
      "#{work_package(id)}/summarized_costs_by_type"
    end

    add_api_path :cost_type do |id|
      "#{root}/cost_types/#{id}"
    end

    add_api_endpoint 'API::V3::Root' do
      mount ::API::V3::CostEntries::CostEntriesAPI
      mount ::API::V3::CostTypes::CostTypesAPI
    end

    add_api_endpoint 'API::V3::WorkPackages::WorkPackagesAPI', :id do
      mount ::API::V3::CostEntries::CostEntriesByWorkPackageAPI
    end

    extend_api_response(:v3, :work_packages, :work_package) do
      include Redmine::I18n
      include ActionView::Helpers::NumberHelper
      prepend API::V3::CostsApiUserPermissionCheck

      link :logCosts,
           cache_if: -> {
             current_user_allowed_to(:log_costs, context: represented.project) ||
               current_user_allowed_to(:log_own_costs, context: represented.project)
           } do
        next unless represented.costs_enabled? && represented.persisted?

        {
          href: new_work_packages_cost_entry_path(represented),
          type: 'text/html',
          title: "Log costs on #{represented.subject}"
        }
      end

      link :showCosts,
           cache_if: -> {
             current_user_allowed_to(:view_cost_entries, context: represented.project) ||
               current_user_allowed_to(:view_own_cost_entries, context: represented.project)
           } do
        next unless represented.persisted? && represented.project.costs_enabled?

        {
          href: cost_reports_path(represented.project_id,
                                  'fields[]': 'WorkPackageId',
                                  'operators[WorkPackageId]': '=',
                                  'values[WorkPackageId]': represented.id,
                                  set_filter: 1),
          type: 'text/html',
          title: "Show cost entries"
        }
      end

      property :labor_costs,
               exec_context: :decorator,
               if: ->(*) { labor_costs_visible? },
               skip_parse: true,
               render_nil: true,
               uncacheable: true

      property :material_costs,
               exec_context: :decorator,
               if: ->(*) { material_costs_visible? },
               skip_parse: true,
               render_nil: true,
               uncacheable: true

      property :overall_costs,
               exec_context: :decorator,
               if: ->(*) { overall_costs_visible? },
               skip_parse: true,
               render_nil: true,
               uncacheable: true

      resource :costsByType,
               link: ->(*) {
                 next unless costs_by_type_visible?

                 {
                   href: api_v3_paths.summarized_work_package_costs_by_type(represented.id)
                 }
               },
               getter: ->(*) {
                 ::API::V3::CostEntries::WorkPackageCostsByTypeRepresenter.new(represented, current_user: current_user)
               },
               setter: ->(*) {},
               skip_render: ->(*) { !costs_by_type_visible? }

      send(:define_method, :overall_costs) do
        number_to_currency(represented.overall_costs)
      end

      send(:define_method, :labor_costs) do
        number_to_currency(represented.labor_costs)
      end

      send(:define_method, :material_costs) do
        number_to_currency(represented.material_costs)
      end
    end

    extend_api_response(:v3, :work_packages, :schema, :work_package_schema) do
      # N.B. in the long term we should have a type like "Currency", but that requires a proper
      # format and not a string like "10 EUR"
      schema :overall_costs,
             type: 'String',
             required: false,
             writable: false,
             show_if: ->(*) { represented.project && represented.project.costs_enabled? }

      schema :labor_costs,
             type: 'String',
             required: false,
             writable: false,
             show_if: ->(*) { represented.project && represented.project.costs_enabled? }

      schema :material_costs,
             type: 'String',
             required: false,
             writable: false,
             show_if: ->(*) { represented.project && represented.project.costs_enabled? }

      schema :costs_by_type,
             type: 'Collection',
             name_source: :spent_units,
             required: false,
             show_if: ->(*) { represented.project && represented.project.costs_enabled? },
             writable: false
    end

    extend_api_response(:v3, :work_packages, :schema, :work_package_sums_schema) do
      schema :overall_costs,
             type: 'String',
             required: false,
             writable: false,
             show_if: ->(*) {
               ::Setting.work_package_list_summable_columns.include?('overall_costs')
             }
      schema :labor_costs,
             type: 'String',
             required: false,
             writable: false,
             show_if: ->(*) {
               ::Setting.work_package_list_summable_columns.include?('labor_costs')
             }
      schema :material_costs,
             type: 'String',
             required: false,
             writable: false,
             show_if: ->(*) {
               ::Setting.work_package_list_summable_columns.include?('material_costs')
             }
    end

    extend_api_response(:v3, :work_packages, :work_package_sums) do
      include ActionView::Helpers::NumberHelper

      property :overall_costs,
               exec_context: :decorator,
               getter: ->(*) {
                 number_to_currency(represented.overall_costs)
               },
               if: ->(*) {
                 ::Setting.work_package_list_summable_columns.include?('overall_costs')
               }

      property :labor_costs,
               exec_context: :decorator,
               getter: ->(*) {
                 number_to_currency(represented.labor_costs)
               },
               if: ->(*) {
                 ::Setting.work_package_list_summable_columns.include?('labor_costs')
               }

      property :material_costs,
               exec_context: :decorator,
               getter: ->(*) {
                 number_to_currency(represented.material_costs)
               },
               if: ->(*) {
                 ::Setting.work_package_list_summable_columns.include?('material_costs')
               }
    end

    config.to_prepare do
      Costs::Patches::MembersPatch.mixin!

      ##
      # Add a new group
      cost_attributes = %i(costs_by_type labor_costs material_costs overall_costs)
      ::Type.add_default_group(:costs, :label_cost_plural)
      ::Type.add_default_mapping(:costs, *cost_attributes)

      constraint = ->(_type, project: nil) {
        project.nil? || project.costs_enabled?
      }

      cost_attributes.each do |attribute|
        ::Type.add_constraint attribute, constraint
      end

      Queries::Register.column Query, Costs::QueryCurrencyColumn
    end
  end
end
