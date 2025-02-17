#import <Foundation/Foundation.h>
#import <libobjsee.framework/Headers/tracer.h>
#import <os/log.h>
#import <sqlite3.h>

static sqlite3 *g_db;

static kern_return_t init_db(void) {
    NSString *db_path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"objc_args.db"];
    if (sqlite3_open(db_path.UTF8String, &g_db) != SQLITE_OK) {
        return KERN_FAILURE;
    }
	os_log(OS_LOG_DEFAULT, "Database opened at %s", db_path.UTF8String);
    
    const char *schema = "CREATE TABLE IF NOT EXISTS method_args (class TEXT, method TEXT, arg_index INTEGER, arg_class TEXT, UNIQUE(class, method, arg_index, arg_class))";
    char *error = NULL;
    if (sqlite3_exec(g_db, schema, NULL, NULL, &error) != SQLITE_OK) {
        sqlite3_free(error);
        return KERN_FAILURE;
    }
    
    return KERN_SUCCESS;
}

static kern_return_t record_arg(const char *class_name, const char *method_name, int arg_idx, const char *arg_class) {
    sqlite3_stmt *stmt;
    const char *query = "INSERT OR IGNORE INTO method_args (class, method, arg_index, arg_class) VALUES (?, ?, ?, ?)";
    if (sqlite3_prepare_v2(g_db, query, -1, &stmt, NULL) != SQLITE_OK) {
        return KERN_FAILURE;
    }
    
    sqlite3_bind_text(stmt, 1, class_name, -1, SQLITE_STATIC);
    sqlite3_bind_text(stmt, 2, method_name, -1, SQLITE_STATIC);
    sqlite3_bind_int(stmt, 3, arg_idx);
    sqlite3_bind_text(stmt, 4, arg_class, -1, SQLITE_STATIC);
    int result = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    
    return (result == SQLITE_DONE) ? KERN_SUCCESS : KERN_FAILURE;
}

static void event_handler(const tracer_event_t *event, void *context) {
    if (event->class_name == NULL || event->method_name == NULL || event->argument_count == 0) {
        return;
    }
    
    for (uint32_t i = 0; i < event->argument_count; i++) {
        const char *arg_type = event->arguments[i].objc_class_name;
        if (arg_type != NULL) {
            record_arg(event->class_name, event->method_name, i, arg_type);
        }
    }
}

__attribute__((constructor)) static void init(void) {
    if (init_db() != KERN_SUCCESS) {
        os_log_error(OS_LOG_DEFAULT, "Failed to initialize database");
        return;
    }
    
    tracer_config_t config = (tracer_config_t){
        .transport = TRACER_TRANSPORT_CUSTOM,
        .format = (tracer_format_options_t){
            .include_colors = false,
            .include_formatted_trace = true,
            .include_event_json = false,
            .output_as_json = false,
            .include_thread_id = false,
            .include_indents = false,
            .args = TRACER_ARG_FORMAT_CLASS
        }
    };
    
    tracer_error_t *error = NULL;
    tracer_t *tracer = tracer_create_with_config(config, &error);
    if (tracer == NULL) {
        os_log_error(OS_LOG_DEFAULT, "Failed to create tracer: %s", error->message);
        free_error(error);
        return;
    }
    
    tracer_set_output_handler(tracer, event_handler, NULL);
    if (tracer_start(tracer) != TRACER_SUCCESS) {
        os_log_error(OS_LOG_DEFAULT, "Failed to start tracer");
        return;
    }    
}