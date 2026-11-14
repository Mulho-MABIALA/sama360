import { Body, Controller, HttpCode, Post } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { z } from 'zod';
import { Public } from '../../shared/auth/decorators';
import { parse } from '../../shared/http/zod';
import { AuthService } from './auth.service';

const RequestOtp = z.object({ phone: z.string().min(6).max(25) });
const VerifyOtp = z.object({
  phone: z.string().min(6).max(25),
  code: z.string().regex(/^\d{6}$/, 'Le code contient 6 chiffres'),
  deviceId: z.string().max(120).optional(),
});
const RefreshBody = z.object({ refreshToken: z.string().min(20) });

@Controller('v1/auth')
export class AuthController {
  constructor(private readonly auth: AuthService) {}

  @Public()
  @Throttle({ default: { limit: 10, ttl: 60_000 } })
  @Post('otp/request')
  @HttpCode(200)
  requestOtp(@Body() body: unknown) {
    const { phone } = parse(RequestOtp, body);
    return this.auth.requestOtp(phone);
  }

  @Public()
  @Throttle({ default: { limit: 10, ttl: 60_000 } })
  @Post('otp/verify')
  @HttpCode(200)
  verifyOtp(@Body() body: unknown) {
    const { phone, code, deviceId } = parse(VerifyOtp, body);
    return this.auth.verifyOtp(phone, code, deviceId);
  }

  @Public()
  @Post('refresh')
  @HttpCode(200)
  refresh(@Body() body: unknown) {
    const { refreshToken } = parse(RefreshBody, body);
    return this.auth.refresh(refreshToken);
  }

  @Public()
  @Post('logout')
  @HttpCode(204)
  async logout(@Body() body: unknown) {
    const { refreshToken } = parse(RefreshBody, body);
    await this.auth.logout(refreshToken);
  }
}
