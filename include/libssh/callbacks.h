#ifndef LIBSSH_CALLBACKS_H
#define LIBSSH_CALLBACKS_H

#include <libssh/libssh.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

struct ssh_callbacks_struct {
	size_t size;
	void *userdata;
	ssh_auth_callback auth_function;
	ssh_log_callback log_function;
	void (*connect_status_function)(void *userdata, float status);
	void (*global_request_function)(ssh_session session, void *message, void *userdata);
	ssh_channel (*channel_open_request_x11_function)(ssh_session session,
	    const char *originator_address, int originator_port, void *userdata);
	ssh_channel (*channel_open_request_auth_agent_function)(ssh_session session,
	    void *userdata);
	ssh_channel (*channel_open_request_forwarded_tcpip_function)(ssh_session session,
	    const char *destination_address, int destination_port,
	    const char *originator_address, int originator_port, void *userdata);
};
typedef struct ssh_callbacks_struct *ssh_callbacks;

struct ssh_server_callbacks_struct {
	size_t size;
	void *userdata;
	int (*auth_password_function)(ssh_session session, const char *user,
	    const char *password, void *userdata);
	int (*auth_none_function)(ssh_session session, const char *user,
	    void *userdata);
	int (*auth_gssapi_mic_function)(ssh_session session, const char *user,
	    const char *principal, void *userdata);
	int (*auth_pubkey_function)(ssh_session session, const char *user,
	    struct ssh_key_struct *pubkey, char signature_state, void *userdata);
	int (*service_request_function)(ssh_session session, const char *service,
	    void *userdata);
	ssh_channel (*channel_open_request_session_function)(ssh_session session,
	    void *userdata);
	void *gssapi_select_oid_function;
	void *gssapi_accept_sec_ctx_function;
	void *gssapi_verify_mic_function;
};
typedef struct ssh_server_callbacks_struct *ssh_server_callbacks;

struct ssh_channel_callbacks_struct {
	size_t size;
	void *userdata;
	int (*channel_data_function)(ssh_session session, ssh_channel channel,
	    void *data, uint32_t len, int is_stderr, void *userdata);
	void (*channel_eof_function)(ssh_session session, ssh_channel channel,
	    void *userdata);
	void (*channel_close_function)(ssh_session session, ssh_channel channel,
	    void *userdata);
	void (*channel_signal_function)(ssh_session session, ssh_channel channel,
	    const char *signal, void *userdata);
	void (*channel_exit_status_function)(ssh_session session, ssh_channel channel,
	    int exit_status, void *userdata);
	void (*channel_exit_signal_function)(ssh_session session, ssh_channel channel,
	    const char *signal, int core, const char *errmsg, const char *lang,
	    void *userdata);
	int (*channel_pty_request_function)(ssh_session session, ssh_channel channel,
	    const char *term, int width, int height, int pxwidth, int pwheight,
	    void *userdata);
	int (*channel_shell_request_function)(ssh_session session, ssh_channel channel,
	    void *userdata);
	void (*channel_auth_agent_req_function)(ssh_session session, ssh_channel channel,
	    void *userdata);
	void (*channel_x11_req_function)(ssh_session session, ssh_channel channel,
	    int single_connection, const char *auth_protocol, const char *auth_cookie,
	    uint32_t screen_number, void *userdata);
	int (*channel_pty_window_change_function)(ssh_session session, ssh_channel channel,
	    int width, int height, int pxwidth, int pwheight, void *userdata);
	int (*channel_exec_request_function)(ssh_session session, ssh_channel channel,
	    const char *command, void *userdata);
	int (*channel_env_request_function)(ssh_session session, ssh_channel channel,
	    const char *env_name, const char *env_value, void *userdata);
	int (*channel_subsystem_request_function)(ssh_session session, ssh_channel channel,
	    const char *subsystem, void *userdata);
	int (*channel_write_wontblock_function)(ssh_session session, ssh_channel channel,
	    uint32_t bytes, void *userdata);
};
typedef struct ssh_channel_callbacks_struct *ssh_channel_callbacks;

#define ssh_callbacks_init(p) do { \
	(p)->size = sizeof(*(p)); \
} while (0)

int ssh_set_callbacks(ssh_session session, ssh_callbacks cb);
int ssh_set_server_callbacks(ssh_session session, ssh_server_callbacks cb);
int ssh_set_channel_callbacks(ssh_channel channel, ssh_channel_callbacks cb);

#ifdef __cplusplus
}
#endif

#endif /* LIBSSH_CALLBACKS_H */
