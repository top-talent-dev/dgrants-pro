class TrialEvent < ActiveRecord::Base
  self.inheritance_column = :_type_disabled

  # Associations
  #----------------------------------------------------------------------
  belongs_to  :vpd
  belongs_to  :vpd_event
  belongs_to  :trial
  belongs_to  :dependency,        class_name: "TrialEvent"

  has_many    :subsequent_events, class_name: "TrialEvent", foreign_key: "dependency_id"
  has_many    :site_events

  # Validations
  #----------------------------------------------------------------------
  validates_presence_of :event_id, :type
  validates_uniqueness_of :event_id, scope: :trial_id
  
  # Scopes
  #----------------------------------------------------------------------
  scope :events,            -> (type) {where(type: type)}
  scope :activated_events,  -> {where(status: 1)}

  # Callbacks
  #----------------------------------------------------------------------
  after_update :sync_for_update

  # Attribute methods
  #----------------------------------------------------------------------
  # Public: Set event ID as CAPs
  def event_id=(val)
    self[:event_id] = val.upcase
  end

  # Public: Get type label for type
  def type_label
    VpdEvent::TYPE_LABEL[self.type]
  end

  # Public: Get status label
  def status_label
    self.status==0 ? "Disabled" : "Active"
  end

  # Public: Get maximum order of a trial event to be created
  def self.max_order_in_fields(trial, event_type)
    where(trial: trial, type: event_type).maximum(:order)
  end

  # Collection methods
  #----------------------------------------------------------------------
  # Public: Set sync to synced status
  def sync_for_synced
    self.update_attributes(sync: 0)
  end

  # Private methods
  #----------------------------------------------------------------------
  private

  # Private: Set sync to updated status
  def sync_for_update
    self.update_attributes(sync: 1) if !self.sync_changed?  &&  sync != 1
  end

  FIELD_HASH_ARRAY =  [ { name:   "mysql_trial_event_id",         type: "int(11)",          default: "NULL"},
                        { name:   "event_id",                     type: "varchar(255)",     default: "''"},
                        { name:   "type",                         type: "varchar(255)",     default: "'Single Event'"},
                        { name:   "description",                  type: "varchar(255)",     default: "''"},
                        { name:   "days",                         type: "int(11)",          default: "NULL"},
                        { name:   "editable",                     type: "boolean",          default: true},
                        { name:   "status",                       type: "varchar(255)",     default: "NULL"},
                        { name:   "mysql_trial_id",               type: "int(11)",          default: "NULL" },
                        { name:   "mysql_vpd_event_id",           type: "int(11)",          default: "NULL"},
                        { name:   "mysql_dependency_id",          type: "int(11)",          default: "NULL"},
                        { name:   "created_at",                   type: "timestamp",        default: "NULL"},
                        { name:   "updated_at",                   type: "timestamp",        default: "NULL"}
                      ]
  MYSQL_TABLE_NAME = Vpd::MYSQL_TABLE_NAME_PREFIX + "trial_events"

  def self.data_to_mysql(vpd, connection)
    p ">>>>>>>>>>>>TrialEvent Data To Mysql---------vpd : #{vpd.name}>>>>>>>>>>>>>>>"
    Vpd.create_mysql_table(connection, MYSQL_TABLE_NAME, FIELD_HASH_ARRAY)

    query_count=0 and queries=""
    data = TrialEvent.where("vpd_id = #{vpd.id} AND (sync > 0 OR sync IS NULL)")
    data.each do |item|
      insert_query = update_query = value_query = ""
      FIELD_HASH_ARRAY.each do |field|
        # p ">>>>>>>>>>>>>field_name : #{field[:name]} => '#{item[field[:name]]}' >>>>>>>>>>>>>>>>"
        insert_query += "`#{field[:name]}`, "
        update_query += "`#{field[:name]}`="
        if field[:type] == "timestamp" || field[:type] == "datetime"
          value_query += item[field[:name]].present? ? "\"#{item[field[:name]].to_s(:db)}\", " : "null, "
          update_query += item[field[:name]].present? ? "\"#{item[field[:name]].to_s(:db)}\", " : "null, "
        elsif (field[:type] == "int(11)" && !field[:name].include?("mysql_")) || field[:type] == "boolean"
          value_query += item[field[:name]].nil? ? "0, " : "#{item[field[:name]]}, "
          update_query += item[field[:name]].nil? ? "0, " : "#{item[field[:name]]}, "
        else
          if field[:name].include?("mysql_")
            if field[:name] == "mysql_trial_event_id"
              value_query  += "#{item.id}, "
              update_query += "#{item.id}, "
            else
              field_name    = field[:name].include?("mysql_") ? field[:name].from(6).to(-1) : field[:name]
              value_query  += item[field_name].nil? ? "NULL, " : "#{item[field_name]}, "
              update_query += item[field_name].nil? ? "NULL, " : "#{item[field_name]}, "
            end
          elsif field[:name] == "type"
            value_query += item[field[:name]].present? ? "\"#{VpdEvent::TYPE_LABEL[item[field[:name]]]}\", " : "'', "
            update_query += item[field[:name]].present? ? "\"#{VpdEvent::TYPE_LABEL[item[field[:name]]]}\", " : "'', "
          elsif field[:name] == "status"
            value_query += item[field[:name]].present? ? "\"#{Vpd::STATUS[item[field[:name]]]}\", " : "'', "
            update_query += item[field[:name]].present? ? "\"#{Vpd::STATUS[item[field[:name]]]}\", " : "'', "
          else
            value_query  += item[field[:name]].nil? ? "'', " : "\"#{item[field[:name]].to_s.gsub('"', '\"')}\", "
            update_query += item[field[:name]].nil? ? "'', " : "\"#{item[field[:name]].to_s.gsub('"', '\"')}\", "
          end
        end
      end
      insert_query = insert_query.from(0).to(-3)
      value_query = value_query.from(0).to(-3)
      query = insert_query = "INSERT INTO #{MYSQL_TABLE_NAME}(#{insert_query}) VALUES (#{value_query});"
      update_query = "UPDATE #{MYSQL_TABLE_NAME} SET #{update_query.from(0).to(-3)} WHERE `mysql_trial_event_id`=#{item.id}"
      if item.sync == 1
        results = connection.query("SELECT count(*) as count FROM #{MYSQL_TABLE_NAME} where `mysql_trial_event_id`=#{item.id};").first
        # p ">>>>>>>>>>>>>>count #{results["count"]}>>>>>>>>>>>>>>>>>>>>"
        query = update_query if results["count"] > 0
      end
      
      queries+=query and query_count+=1
      if query_count == Vpd::BATACH_QUERY_COUNT || index == data_count-1
        connection.query(queries)
        queries="" and query_count=0
        while connection.next_result
          connection.store_result rescue ''
        end
      end
      item.sync_for_synced
    end
  end
end