// Verified app staging and a detached installer. No files are replaced before Restart.
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
static size_t copy_text(NSString *text,char *out,size_t cap){NSData *d=[text dataUsingEncoding:NSUTF8StringEncoding];if(!cap||d.length>=cap)return 0;memcpy(out,d.bytes,d.length);out[d.length]=0;return d.length;}
static BOOL run(NSString *bin,NSArray *args,NSData **output){
 NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:bin];task.arguments=args;task.standardError=NSFileHandle.fileHandleWithNullDevice;
 NSPipe *pipe=output?NSPipe.pipe:nil;task.standardOutput=pipe?:NSFileHandle.fileHandleWithNullDevice;
 if(![task launchAndReturnError:nil])return NO;if(output)*output=[pipe.fileHandleForReading readDataToEndOfFile];[task waitUntilExit];return task.terminationStatus==0;
}
static BOOL valid(NSString *path,NSString *version){
 NSDictionary *info=[NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Info.plist"]];
 return [info[@"CFBundleIdentifier"]isEqual:@"com.debpalash.opal"] && (!version||[info[@"CFBundleShortVersionString"]isEqual:version]) && [[NSFileManager defaultManager]isExecutableFileAtPath:[path stringByAppendingPathComponent:@"Contents/MacOS/Opal"]];
}
size_t opal_update_target(char *out,size_t cap){
 NSString *path=NSBundle.mainBundle.bundlePath.stringByResolvingSymlinksInPath;
 if(![path.pathExtension isEqual:@"app"] || !valid(path,nil) || ![NSFileManager.defaultManager isWritableFileAtPath:path.stringByDeletingLastPathComponent])return 0;
 return copy_text(path,out,cap);
}
size_t opal_update_prepare(const char *archive,const char *target,const char *version,char *out,size_t cap){@autoreleasepool{
 NSString *destination=[NSString stringWithUTF8String:target],*v=[NSString stringWithUTF8String:version];
 if(!valid(destination,nil)||![NSFileManager.defaultManager isWritableFileAtPath:destination.stringByDeletingLastPathComponent])return 0;
 // Reject path traversal before ditto follows any archive paths.
 NSData *listing=nil;if(!run(@"/usr/bin/unzip",@[@"-Z1",[NSString stringWithUTF8String:archive]],&listing)||listing.length>4*1024*1024)return 0;
 NSString *names=[[NSString alloc]initWithData:listing encoding:NSUTF8StringEncoding];if(!names.length)return 0;
 for(NSString *line in [names componentsSeparatedByString:@"\n"]){
  if(!line.length)continue;if(![line hasPrefix:@"Opal.app/"]&&![line hasPrefix:@"__MACOSX/"])return 0;
  if([line.pathComponents containsObject:@".."]||[line hasPrefix:@"/"])return 0;
 }
 NSString *stage=[destination.stringByDeletingLastPathComponent stringByAppendingPathComponent:[@".opal-update." stringByAppendingString:NSUUID.UUID.UUIDString]];
 if(![NSFileManager.defaultManager createDirectoryAtPath:stage withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:nil])return 0;
 NSString *app=[stage stringByAppendingPathComponent:@"Opal.app"];
 BOOL ok=run(@"/usr/bin/ditto",@[@"-x",@"-k",[NSString stringWithUTF8String:archive],stage],NULL)&&valid(app,v)&&run(@"/usr/bin/codesign",@[@"--verify",@"--deep",@"--strict",app],NULL);
 if(!ok||!copy_text(stage,out,cap)){[NSFileManager.defaultManager removeItemAtPath:stage error:nil];return 0;}return strlen(out);
}}
int opal_update_restart(const char *target,const char *stage,const char *version,const char *script){
 NSString *destination=[NSString stringWithUTF8String:target],*directory=[NSString stringWithUTF8String:stage];
 if(![directory.lastPathComponent hasPrefix:@".opal-update."]||![directory.stringByDeletingLastPathComponent isEqual:destination.stringByDeletingLastPathComponent]||!valid(destination,nil)||!valid([directory stringByAppendingPathComponent:@"Opal.app"],[NSString stringWithUTF8String:version]))return 0;
 NSString *helper=[directory stringByAppendingPathComponent:@"install.sh"];
 if(![[NSString stringWithUTF8String:script]writeToFile:helper atomically:YES encoding:NSUTF8StringEncoding error:nil])return 0;
 chmod(helper.fileSystemRepresentation,0500);
 NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:@"/bin/sh"];task.arguments=@[helper,[NSString stringWithFormat:@"%d",getpid()],destination,directory,@"60"];
 task.standardOutput=NSFileHandle.fileHandleWithNullDevice;task.standardError=NSFileHandle.fileHandleWithNullDevice;
 return [task launchAndReturnError:nil];
}
void opal_update_ack(void){
 const char *raw=getenv("OPAL_UPDATE_ACK");if(!raw)return;
 NSString *path=[NSString stringWithUTF8String:raw],*directory=path.stringByDeletingLastPathComponent;
 if(![path.lastPathComponent isEqual:@"ready"]||![directory.lastPathComponent hasPrefix:@".opal-update."])return;
 struct stat info;if(lstat(directory.fileSystemRepresentation,&info)!=0||info.st_uid!=getuid()||!S_ISDIR(info.st_mode))return;
 int fd=open(raw,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,0600);if(fd>=0){write(fd,"ready\n",6);close(fd);}
 unsetenv("OPAL_UPDATE_ACK");
}
void opal_update_discard(const char *stage){
 NSString *directory=[NSString stringWithUTF8String:stage];if([directory.lastPathComponent hasPrefix:@".opal-update."])[NSFileManager.defaultManager removeItemAtPath:directory error:nil];
}
