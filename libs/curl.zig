const std = @import("std");

pub fn create(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "curl",
        .target = target,
        .optimize = optimize,
    });
    lib.addCSourceFiles(.{ .files = srcs });
    lib.addIncludePath(.{ .path = "libs/curl/lib" });
    lib.addIncludePath(.{ .path = "libs/curl/include" });
    lib.installHeadersDirectory("libs/curl/include/curl", "curl");
    lib.linkLibC();
    lib.defineCMacro("BUILDING_LIBCURL", null);
    lib.defineCMacro("CURL_STATICLIB", "1");
    lib.defineCMacro("CURL_DISABLE_LDAP", "1");
    lib.defineCMacro("CURL_DISABLE_LDAPS", "1");
    lib.defineCMacro("USE_MBEDTLS", "1");
    lib.defineCMacro("CURL_DISABLE_DICT", "1");
    lib.defineCMacro("CURL_DISABLE_FILE", "1");
    lib.defineCMacro("CURL_DISABLE_FTP", "1");
    lib.defineCMacro("CURL_DISABLE_GOPHER", "1");
    lib.defineCMacro("CURL_DISABLE_IMAP", "1");
    lib.defineCMacro("CURL_DISABLE_MQTT", "1");
    lib.defineCMacro("CURL_DISABLE_POP3", "1");
    lib.defineCMacro("CURL_DISABLE_RTSP", "1");
    lib.defineCMacro("CURL_DISABLE_SMB", "1");
    lib.defineCMacro("CURL_DISABLE_SMTP", "1");
    lib.defineCMacro("CURL_DISABLE_TELNET", "1");
    lib.defineCMacro("CURL_DISABLE_TFTP", "1");
    lib.defineCMacro("HAVE_LIBZ", "1");
    lib.defineCMacro("HAVE_ZLIB_H", "1");
    if (target.result.os.tag == .windows) {
        lib.linkSystemLibrary("bcrypt");
        return lib;
    }
    lib.defineCMacro("CURL_EXTERN_SYMBOL", "__attribute__ ((__visibility__ (\"default\"))");

    const isDarwin = target.result.isDarwin();
    if (!isDarwin)
        lib.defineCMacro("ENABLE_IPV6", "1");
    lib.defineCMacro("HAVE_ALARM", "1");
    lib.defineCMacro("HAVE_ALLOCA_H", "1");
    lib.defineCMacro("HAVE_ARPA_INET_H", "1");
    lib.defineCMacro("HAVE_ARPA_TFTP_H", "1");
    lib.defineCMacro("HAVE_ASSERT_H", "1");
    lib.defineCMacro("HAVE_BASENAME", "1");
    lib.defineCMacro("HAVE_BOOL_T", "1");
    lib.defineCMacro("HAVE_BUILTIN_AVAILABLE", "1");
    lib.defineCMacro("HAVE_CLOCK_GETTIME_MONOTONIC", "1");
    lib.defineCMacro("HAVE_DLFCN_H", "1");
    lib.defineCMacro("HAVE_ERRNO_H", "1");
    lib.defineCMacro("HAVE_FCNTL", "1");
    lib.defineCMacro("HAVE_FCNTL_H", "1");
    lib.defineCMacro("HAVE_FCNTL_O_NONBLOCK", "1");
    lib.defineCMacro("HAVE_FREEADDRINFO", "1");
    lib.defineCMacro("HAVE_FTRUNCATE", "1");
    lib.defineCMacro("HAVE_GETADDRINFO", "1");
    lib.defineCMacro("HAVE_GETEUID", "1");
    lib.defineCMacro("HAVE_GETPPID", "1");
    lib.defineCMacro("HAVE_GETHOSTBYNAME", "1");
    if (!isDarwin)
        lib.defineCMacro("HAVE_GETHOSTBYNAME_R", "1");
    lib.defineCMacro("HAVE_GETHOSTBYNAME_R_6", "1");
    lib.defineCMacro("HAVE_GETHOSTNAME", "1");
    lib.defineCMacro("HAVE_GETPPID", "1");
    lib.defineCMacro("HAVE_GETPROTOBYNAME", "1");
    lib.defineCMacro("HAVE_GETPEERNAME", "1");
    lib.defineCMacro("HAVE_GETSOCKNAME", "1");
    lib.defineCMacro("HAVE_IF_NAMETOINDEX", "1");
    lib.defineCMacro("HAVE_GETPWUID", "1");
    lib.defineCMacro("HAVE_GETPWUID_R", "1");
    lib.defineCMacro("HAVE_GETRLIMIT", "1");
    lib.defineCMacro("HAVE_GETTIMEOFDAY", "1");
    lib.defineCMacro("HAVE_GMTIME_R", "1");
    lib.defineCMacro("HAVE_IFADDRS_H", "1");
    lib.defineCMacro("HAVE_INET_ADDR", "1");
    lib.defineCMacro("HAVE_INET_PTON", "1");
    lib.defineCMacro("HAVE_SA_FAMILY_T", "1");
    lib.defineCMacro("HAVE_INTTYPES_H", "1");
    lib.defineCMacro("HAVE_IOCTL", "1");
    lib.defineCMacro("HAVE_IOCTL_FIONBIO", "1");
    lib.defineCMacro("HAVE_IOCTL_SIOCGIFADDR", "1");
    lib.defineCMacro("HAVE_LDAP_URL_PARSE", "1");
    lib.defineCMacro("HAVE_LIBGEN_H", "1");
    lib.defineCMacro("HAVE_IDN2_H", "1");
    lib.defineCMacro("HAVE_LL", "1");
    lib.defineCMacro("HAVE_LOCALE_H", "1");
    lib.defineCMacro("HAVE_LOCALTIME_R", "1");
    lib.defineCMacro("HAVE_LONGLONG", "1");
    lib.defineCMacro("HAVE_MALLOC_H", "1");
    lib.defineCMacro("HAVE_MEMORY_H", "1");
    if (!isDarwin)
        lib.defineCMacro("HAVE_MSG_NOSIGNAL", "1");
    lib.defineCMacro("HAVE_NETDB_H", "1");
    lib.defineCMacro("HAVE_NETINET_IN_H", "1");
    lib.defineCMacro("HAVE_NETINET_TCP_H", "1");

    if (target.result.os.tag == .linux)
        lib.defineCMacro("HAVE_LINUX_TCP_H", "1");
    lib.defineCMacro("HAVE_NET_IF_H", "1");
    lib.defineCMacro("HAVE_PIPE", "1");
    lib.defineCMacro("HAVE_POLL", "1");
    lib.defineCMacro("HAVE_POLL_FINE", "1");
    lib.defineCMacro("HAVE_POLL_H", "1");
    lib.defineCMacro("HAVE_POSIX_STRERROR_R", "1");
    lib.defineCMacro("HAVE_PTHREAD_H", "1");
    lib.defineCMacro("HAVE_PWD_H", "1");
    lib.defineCMacro("HAVE_RECV", "1");
    lib.defineCMacro("HAVE_SELECT", "1");
    lib.defineCMacro("HAVE_SEND", "1");
    lib.defineCMacro("HAVE_FSETXATTR", "1");
    lib.defineCMacro("HAVE_FSETXATTR_5", "1");
    lib.defineCMacro("HAVE_SETJMP_H", "1");
    lib.defineCMacro("HAVE_SETLOCALE", "1");
    lib.defineCMacro("HAVE_SETRLIMIT", "1");
    lib.defineCMacro("HAVE_SETSOCKOPT", "1");
    lib.defineCMacro("HAVE_SIGACTION", "1");
    lib.defineCMacro("HAVE_SIGINTERRUPT", "1");
    lib.defineCMacro("HAVE_SIGNAL", "1");
    lib.defineCMacro("HAVE_SIGNAL_H", "1");
    lib.defineCMacro("HAVE_SIGSETJMP", "1");
    lib.defineCMacro("HAVE_SOCKADDR_IN6_SIN6_SCOPE_ID", "1");
    lib.defineCMacro("HAVE_SOCKET", "1");
    lib.defineCMacro("HAVE_STDBOOL_H", "1");
    lib.defineCMacro("HAVE_STDINT_H", "1");
    lib.defineCMacro("HAVE_STDIO_H", "1");
    lib.defineCMacro("HAVE_STDLIB_H", "1");
    lib.defineCMacro("HAVE_STRCASECMP", "1");
    lib.defineCMacro("HAVE_STRDUP", "1");
    lib.defineCMacro("HAVE_STRERROR_R", "1");
    lib.defineCMacro("HAVE_STRINGS_H", "1");
    lib.defineCMacro("HAVE_STRING_H", "1");
    lib.defineCMacro("HAVE_STRSTR", "1");
    lib.defineCMacro("HAVE_STRTOK_R", "1");
    lib.defineCMacro("HAVE_STRTOLL", "1");
    lib.defineCMacro("HAVE_STRUCT_SOCKADDR_STORAGE", "1");
    lib.defineCMacro("HAVE_STRUCT_TIMEVAL", "1");
    lib.defineCMacro("HAVE_SYS_IOCTL_H", "1");
    lib.defineCMacro("HAVE_SYS_PARAM_H", "1");
    lib.defineCMacro("HAVE_SYS_POLL_H", "1");
    lib.defineCMacro("HAVE_SYS_RESOURCE_H", "1");
    lib.defineCMacro("HAVE_SYS_SELECT_H", "1");
    lib.defineCMacro("HAVE_SYS_SOCKET_H", "1");
    lib.defineCMacro("HAVE_SYS_STAT_H", "1");
    lib.defineCMacro("HAVE_SYS_TIME_H", "1");
    lib.defineCMacro("HAVE_SYS_TYPES_H", "1");
    lib.defineCMacro("HAVE_SYS_UIO_H", "1");
    lib.defineCMacro("HAVE_SYS_UN_H", "1");
    lib.defineCMacro("HAVE_TERMIOS_H", "1");
    lib.defineCMacro("HAVE_TERMIO_H", "1");
    lib.defineCMacro("HAVE_TIME_H", "1");
    lib.defineCMacro("HAVE_UNAME", "1");
    lib.defineCMacro("HAVE_UNISTD_H", "1");
    lib.defineCMacro("HAVE_UTIME", "1");
    lib.defineCMacro("HAVE_UTIMES", "1");
    lib.defineCMacro("HAVE_UTIME_H", "1");
    lib.defineCMacro("HAVE_VARIADIC_MACROS_C99", "1");
    lib.defineCMacro("HAVE_VARIADIC_MACROS_GCC", "1");
    lib.defineCMacro("OS", "\"Linux\"");
    lib.defineCMacro("RANDOM_FILE", "\"/dev/urandom\"");
    lib.defineCMacro("RECV_TYPE_ARG1", "int");
    lib.defineCMacro("RECV_TYPE_ARG2", "void *");
    lib.defineCMacro("RECV_TYPE_ARG3", "size_t");
    lib.defineCMacro("RECV_TYPE_ARG4", "int");
    lib.defineCMacro("RECV_TYPE_RETV", "ssize_t");
    lib.defineCMacro("SEND_QUAL_ARG2", "const");
    lib.defineCMacro("SEND_TYPE_ARG1", "int");
    lib.defineCMacro("SEND_TYPE_ARG2", "void *");
    lib.defineCMacro("SEND_TYPE_ARG3", "size_t");
    lib.defineCMacro("SEND_TYPE_ARG4", "int");
    lib.defineCMacro("SEND_TYPE_RETV", "ssize_t");
    lib.defineCMacro("SIZEOF_INT", "4");
    lib.defineCMacro("SIZEOF_SHORT", "2");
    lib.defineCMacro("SIZEOF_LONG", "8");
    lib.defineCMacro("SIZEOF_OFF_T", "8");
    lib.defineCMacro("SIZEOF_CURL_OFF_T", "8");
    lib.defineCMacro("SIZEOF_SIZE_T", "8");
    lib.defineCMacro("SIZEOF_TIME_T", "8");
    lib.defineCMacro("STDC_HEADERS", "1");
    lib.defineCMacro("TIME_WITH_SYS_TIME", "1");
    lib.defineCMacro("USE_THREADS_POSIX", "1");
    lib.defineCMacro("USE_UNIX_SOCKETS", null);
    lib.defineCMacro("_FILE_OFFSET_BITS", "64");
    return lib;
}

const srcs = &.{
    "libs/curl/lib/cookie.c",
    "libs/curl/lib/http_chunks.c",
    "libs/curl/lib/escape.c",
    "libs/curl/lib/version_win32.c",
    "libs/curl/lib/url.c",
    "libs/curl/lib/base64.c",
    "libs/curl/lib/mqtt.c",
    "libs/curl/lib/setopt.c",
    "libs/curl/lib/telnet.c",
    "libs/curl/lib/hostip.c",
    "libs/curl/lib/curl_gethostname.c",
    "libs/curl/lib/connect.c",
    "libs/curl/lib/socks_sspi.c",
    "libs/curl/lib/cf-socket.c",
    "libs/curl/lib/curl_fnmatch.c",
    "libs/curl/lib/curl_gssapi.c",
    "libs/curl/lib/http1.c",
    "libs/curl/lib/multi.c",
    "libs/curl/lib/gopher.c",
    "libs/curl/lib/noproxy.c",
    "libs/curl/lib/curl_sasl.c",
    "libs/curl/lib/dict.c",
    "libs/curl/lib/bufref.c",
    "libs/curl/lib/slist.c",
    "libs/curl/lib/curl_trc.c",
    "libs/curl/lib/vtls/rustls.c",
    "libs/curl/lib/vtls/mbedtls.c",
    "libs/curl/lib/vtls/wolfssl.c",
    "libs/curl/lib/vtls/schannel.c",
    "libs/curl/lib/vtls/gtls.c",
    "libs/curl/lib/vtls/sectransp.c",
    "libs/curl/lib/vtls/vtls.c",
    "libs/curl/lib/vtls/mbedtls_threadlock.c",
    "libs/curl/lib/vtls/schannel_verify.c",
    "libs/curl/lib/vtls/hostcheck.c",
    "libs/curl/lib/vtls/bearssl.c",
    "libs/curl/lib/vtls/openssl.c",
    "libs/curl/lib/vtls/x509asn1.c",
    "libs/curl/lib/vtls/keylog.c",
    "libs/curl/lib/file.c",
    "libs/curl/lib/socks_gssapi.c",
    "libs/curl/lib/select.c",
    "libs/curl/lib/socketpair.c",
    "libs/curl/lib/curl_memrchr.c",
    "libs/curl/lib/cfilters.c",
    "libs/curl/lib/strtok.c",
    "libs/curl/lib/version.c",
    "libs/curl/lib/fopen.c",
    "libs/curl/lib/http_aws_sigv4.c",
    "libs/curl/lib/mprintf.c",
    "libs/curl/lib/curl_path.c",
    "libs/curl/lib/parsedate.c",
    "libs/curl/lib/rename.c",
    "libs/curl/lib/ftplistparser.c",
    "libs/curl/lib/content_encoding.c",
    "libs/curl/lib/mime.c",
    "libs/curl/lib/rand.c",
    "libs/curl/lib/curl_des.c",
    "libs/curl/lib/curl_ntlm_core.c",
    "libs/curl/lib/pop3.c",
    "libs/curl/lib/curl_sspi.c",
    "libs/curl/lib/smb.c",
    "libs/curl/lib/conncache.c",
    "libs/curl/lib/inet_pton.c",
    "libs/curl/lib/if2ip.c",
    "libs/curl/lib/openldap.c",
    "libs/curl/lib/http_digest.c",
    "libs/curl/lib/cf-h1-proxy.c",
    "libs/curl/lib/asyn-thread.c",
    "libs/curl/lib/strerror.c",
    "libs/curl/lib/ftp.c",
    "libs/curl/lib/strdup.c",
    "libs/curl/lib/memdebug.c",
    "libs/curl/lib/speedcheck.c",
    "libs/curl/lib/vquic/curl_ngtcp2.c",
    "libs/curl/lib/vquic/curl_msh3.c",
    "libs/curl/lib/vquic/vquic.c",
    "libs/curl/lib/vquic/curl_quiche.c",
    "libs/curl/lib/getinfo.c",
    "libs/curl/lib/http2.c",
    "libs/curl/lib/vauth/oauth2.c",
    "libs/curl/lib/vauth/vauth.c",
    "libs/curl/lib/vauth/digest_sspi.c",
    "libs/curl/lib/vauth/digest.c",
    "libs/curl/lib/vauth/cram.c",
    "libs/curl/lib/vauth/cleartext.c",
    "libs/curl/lib/vauth/krb5_sspi.c",
    "libs/curl/lib/vauth/spnego_sspi.c",
    "libs/curl/lib/vauth/ntlm_sspi.c",
    "libs/curl/lib/vauth/spnego_gssapi.c",
    "libs/curl/lib/vauth/ntlm.c",
    "libs/curl/lib/vauth/krb5_gssapi.c",
    "libs/curl/lib/vauth/gsasl.c",
    "libs/curl/lib/md4.c",
    "libs/curl/lib/bufq.c",
    "libs/curl/lib/curl_get_line.c",
    "libs/curl/lib/hostip4.c",
    "libs/curl/lib/curl_rtmp.c",
    "libs/curl/lib/amigaos.c",
    "libs/curl/lib/share.c",
    "libs/curl/lib/warnless.c",
    "libs/curl/lib/hostsyn.c",
    "libs/curl/lib/md5.c",
    "libs/curl/lib/strtoofft.c",
    "libs/curl/lib/altsvc.c",
    "libs/curl/lib/formdata.c",
    "libs/curl/lib/dynbuf.c",
    "libs/curl/lib/curl_addrinfo.c",
    "libs/curl/lib/hostasyn.c",
    "libs/curl/lib/doh.c",
    "libs/curl/lib/curl_ntlm_wb.c",
    "libs/curl/lib/easygetopt.c",
    "libs/curl/lib/ldap.c",
    "libs/curl/lib/nonblock.c",
    "libs/curl/lib/idn.c",
    "libs/curl/lib/pingpong.c",
    "libs/curl/lib/imap.c",
    "libs/curl/lib/vssh/libssh.c",
    "libs/curl/lib/vssh/wolfssh.c",
    "libs/curl/lib/vssh/libssh2.c",
    "libs/curl/lib/splay.c",
    "libs/curl/lib/krb5.c",
    "libs/curl/lib/progress.c",
    "libs/curl/lib/cf-haproxy.c",
    "libs/curl/lib/easyoptions.c",
    "libs/curl/lib/curl_range.c",
    "libs/curl/lib/curl_endian.c",
    "libs/curl/lib/http_proxy.c",
    "libs/curl/lib/inet_ntop.c",
    "libs/curl/lib/timeval.c",
    "libs/curl/lib/asyn-ares.c",
    "libs/curl/lib/rtsp.c",
    "libs/curl/lib/sha256.c",
    "libs/curl/lib/curl_threads.c",
    "libs/curl/lib/easy.c",
    "libs/curl/lib/dynhds.c",
    "libs/curl/lib/tftp.c",
    "libs/curl/lib/hsts.c",
    "libs/curl/lib/smtp.c",
    "libs/curl/lib/hash.c",
    "libs/curl/lib/cf-https-connect.c",
    "libs/curl/lib/getenv.c",
    "libs/curl/lib/headers.c",
    "libs/curl/lib/system_win32.c",
    "libs/curl/lib/http_ntlm.c",
    "libs/curl/lib/psl.c",
    "libs/curl/lib/ws.c",
    "libs/curl/lib/hostip6.c",
    "libs/curl/lib/curl_multibyte.c",
    "libs/curl/lib/netrc.c",
    "libs/curl/lib/llist.c",
    "libs/curl/lib/urlapi.c",
    "libs/curl/lib/strcase.c",
    "libs/curl/lib/sendf.c",
    "libs/curl/lib/timediff.c",
    "libs/curl/lib/http.c",
    "libs/curl/lib/cf-h2-proxy.c",
    "libs/curl/lib/socks.c",
    "libs/curl/lib/http_negotiate.c",
    "libs/curl/lib/transfer.c",
    "libs/curl/lib/c-hyper.c",
    "libs/curl/lib/hmac.c",
    "libs/curl/lib/fileinfo.c",
};
