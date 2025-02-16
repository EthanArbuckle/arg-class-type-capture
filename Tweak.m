#import <Foundation/Foundation.h>
#import <libobjsee.framework/Headers/tracer.h>
#import <os/log.h>

typedef struct _arg_cache_entry {
    const char *class_name;
    const char *selector;
    const char **arg_types;
    uint32_t arg_count;
} arg_cache_entry_t;

static struct {
    arg_cache_entry_t *entries;
    uint32_t count;
    uint32_t capacity;
} g_cache = {NULL, 0, 0};

static kern_return_t ensure_capacity(void) {
    if (g_cache.entries == NULL) {
        g_cache.capacity = 1024;
        g_cache.entries = malloc(sizeof(arg_cache_entry_t) * g_cache.capacity);
        if (g_cache.entries == NULL) {
            return KERN_NO_SPACE;
        }
        return KERN_SUCCESS;
    }
    
    if (g_cache.count < g_cache.capacity) {
        return KERN_SUCCESS;
    }
    
    uint32_t new_capacity = g_cache.capacity * 2;
    arg_cache_entry_t *new_entries = realloc(g_cache.entries, sizeof(arg_cache_entry_t) * new_capacity);
    if (new_entries == NULL) {
        return KERN_NO_SPACE;
    }
    
    g_cache.entries = new_entries;
    g_cache.capacity = new_capacity;
    return KERN_SUCCESS;
}

static const arg_cache_entry_t *cached_entry_for_class_selector(const char *class_name, const char *selector) {
    for (uint32_t i = 0; i < g_cache.count; i++) {
        if (g_cache.entries[i].class_name == class_name && g_cache.entries[i].selector == selector) {
            return &g_cache.entries[i];
        }
    }
    return NULL;
}

static kern_return_t cache_args_for_class_selector(const char *class_name, const char *selector, const char **arg_types, uint32_t arg_count) {
    if (cached_entry_for_class_selector(class_name, selector) != NULL) {
        return KERN_SUCCESS;
    }
    
    kern_return_t kr = ensure_capacity();
    if (kr != KERN_SUCCESS) {
        return kr;
    }
    
    const char **types = malloc(sizeof(char *) * arg_count);
    if (types == NULL) {
        return KERN_NO_SPACE;
    }
    
    memcpy(types, arg_types, sizeof(char *) * arg_count);
    
    g_cache.entries[g_cache.count].class_name = class_name;
    g_cache.entries[g_cache.count].selector = selector;
    g_cache.entries[g_cache.count].arg_types = types;
    g_cache.entries[g_cache.count].arg_count = arg_count;
    g_cache.count++;
    return KERN_SUCCESS;
}

static kern_return_t dump_cache_to_disk(const char *filepath) {
    FILE *f = fopen(filepath, "w");
    if (f == NULL) {
        return KERN_FAILURE;
    }
    
    for (uint32_t i = 0; i < g_cache.count; i++) {
        fprintf(f, "%s\t%s", g_cache.entries[i].class_name, g_cache.entries[i].selector);
		os_log(OS_LOG_DEFAULT, "[%{public}s %{public}s]", g_cache.entries[i].class_name, g_cache.entries[i].selector);
        for (uint32_t j = 0; j < g_cache.entries[i].arg_count; j++) {
            fprintf(f, "\t%s", g_cache.entries[i].arg_types[j]);
			os_log(OS_LOG_DEFAULT, "  arg %d: %{public}s", j, g_cache.entries[i].arg_types[j]);
        }
        fprintf(f, "\n");
    }
    
    fclose(f);
    return KERN_SUCCESS;
}

static void event_handler(const tracer_event_t *event, void *context) {
    if (event->class_name == NULL || event->method_name == NULL || event->argument_count == 0) {
        return;
    }
    
    if (cached_entry_for_class_selector(event->class_name, event->method_name) != NULL) {
        return;
    }
    
	os_log(OS_LOG_DEFAULT, "[%{public}s %{public}s]", event->class_name, event->method_name);
    
    const char **arg_types = malloc(sizeof(char *) * event->argument_count);
    if (arg_types == NULL) {
        return;
    }
    
    for (uint32_t i = 0; i < event->argument_count; i++) {
        arg_types[i] = event->arguments[i].objc_class_name ? event->arguments[i].objc_class_name : event->arguments[i].type_encoding;
		os_log(OS_LOG_DEFAULT, "  arg %d: %{public}s", i, arg_types[i]);
    }
    
    cache_args_for_class_selector(event->class_name, event->method_name, arg_types, (uint32_t)event->argument_count);
    free(arg_types);
}

__attribute__((constructor)) static void init(void) {

    tracer_config_t config = (tracer_config_t) {
        .transport = TRACER_TRANSPORT_CUSTOM,
        .format = (tracer_format_options_t) {
            .include_colors = false,
            .include_formatted_trace = true,
            .include_event_json = false,
            .output_as_json = false,
            .include_thread_id = false,
            .include_indents = true,
            .indent_char = " ",
            .include_indent_separators = true,
            .indent_separator_char = "|",
            .variable_separator_spacing = false,
            .static_separator_spacing = 2,
            .include_newline_in_formatted_trace = true,
            .args = TRACER_ARG_FORMAT_CLASS
        }
    };
    
    tracer_error_t *error = NULL;
    tracer_t *tracer = tracer_create_with_config(config, &error);
    if (tracer == NULL) {
		os_log_error(OS_LOG_DEFAULT, "Error creating tracer: %{public}s", error->message);
        free_error(error);
        return;
    }
    
    tracer_set_output_handler(tracer, event_handler, NULL);
    if (tracer_start(tracer) != TRACER_SUCCESS) {
		os_log_error(OS_LOG_DEFAULT, "Error starting tracer");
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    
        NSString *tmp = NSTemporaryDirectory();
        dump_cache_to_disk([tmp stringByAppendingPathComponent:@"args.txt"].UTF8String);
    });

	os_log(OS_LOG_DEFAULT, "Tracer started");
}
