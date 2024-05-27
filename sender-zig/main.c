#include <sys/socket.h>
#include <linux/socket.h>
int main(){
int flags =1; 
    if (setsockopt(sfd, SOL_TCP, TCP_NODELAY, (void *)&flags, sizeof(flags))) { perror("ERROR: setsocketopt(), TCP_NODELAY"); exit(0); }; 
 
}
