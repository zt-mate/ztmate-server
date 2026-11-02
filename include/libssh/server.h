#ifndef LIBSSH_SERVER_H
#define LIBSSH_SERVER_H

#include <libssh/libssh.h>

#ifdef __cplusplus
extern "C" {
#endif

enum ssh_bind_options_e {
	SSH_BIND_OPTIONS_BINDADDR = 0,
	SSH_BIND_OPTIONS_BINDPORT,
	SSH_BIND_OPTIONS_BINDPORT_STR,
	SSH_BIND_OPTIONS_HOSTKEY,
	SSH_BIND_OPTIONS_DSAKEY,
	SSH_BIND_OPTIONS_RSAKEY,
	SSH_BIND_OPTIONS_BANNER,
	SSH_BIND_OPTIONS_LOG_VERBOSITY,
	SSH_BIND_OPTIONS_LOG_VERBOSITY_STR,
	SSH_BIND_OPTIONS_ECDSAKEY,
	SSH_BIND_OPTIONS_IMPORT_KEY
};

ssh_bind ssh_bind_new(void);
void ssh_bind_free(ssh_bind sshbind);
int ssh_bind_options_set(ssh_bind sshbind, enum ssh_bind_options_e type, const void *value);
int ssh_bind_options_parse_config(ssh_bind sshbind, const char *filename);
int ssh_bind_listen(ssh_bind sshbind);
int ssh_bind_get_fd(ssh_bind sshbind);
int ssh_bind_accept_fd(ssh_bind sshbind, ssh_session session, int fd);

int ssh_handle_key_exchange(ssh_session session);
void ssh_set_auth_methods(ssh_session session, int auth_methods);

typedef int (*ssh_message_callback)(ssh_session session, ssh_message msg, void *data);
void ssh_set_message_callback(ssh_session session, ssh_message_callback ssh_bind_message_callback, void *data);
int ssh_execute_message_callbacks(ssh_session session);

int ssh_message_type(ssh_message msg);
int ssh_message_subtype(ssh_message msg);
int ssh_message_channel_request_pty_width(ssh_message msg);
int ssh_message_channel_request_pty_height(ssh_message msg);

#ifdef __cplusplus
}
#endif

#endif /* LIBSSH_SERVER_H */
