import { Module } from '@nestjs/common';
import { env } from '../../shared/config/env';
import { AssistantController } from './assistant.controller';
import { AssistantService } from './assistant.service';
import { AnthropicClient, FakeLlmClient, LlmClient } from './llm';

@Module({
  controllers: [AssistantController],
  providers: [
    AssistantService,
    {
      provide: LlmClient,
      useFactory: () => {
        const e = env();
        return e.ASSISTANT_PROVIDER === 'anthropic'
          ? new AnthropicClient(e.ANTHROPIC_API_KEY!, e.ASSISTANT_MODEL)
          : new FakeLlmClient();
      },
    },
  ],
})
export class AssistantModule {}
