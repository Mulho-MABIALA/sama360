import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { FilesModule } from '../files/files.module';
import { AuthController } from './auth.controller';
import { AuthService } from './auth.service';
import { MeController } from './me.controller';
import { ConsoleOtpSender, createOtpSender, OTP_SENDER } from './otp-sender';

@Module({
  imports: [JwtModule.register({}), FilesModule],
  controllers: [AuthController, MeController],
  providers: [
    AuthService,
    ConsoleOtpSender,
    {
      provide: OTP_SENDER,
      useFactory: createOtpSender,
      inject: [ConsoleOtpSender],
    },
  ],
  exports: [AuthService, JwtModule, ConsoleOtpSender],
})
export class AuthModule {}
