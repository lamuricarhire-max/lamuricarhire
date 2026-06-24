import { Module } from '@nestjs/common';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { TypeOrmModule } from '@nestjs/typeorm';
import { AppController } from './app.controller';
import { AppService } from './app.service';

/**
 * AppModule — root module for the LAMURI Car Hire API.
 *
 * As the application grows, feature modules (BookingModule, FleetModule,
 * FinanceModule, etc.) should be imported here. See the architecture
 * overview in docs/00-architecture-overview.md for the suggested build order.
 */
@Module({
  imports: [
    // ConfigModule makes process.env variables available via ConfigService
    // throughout the application. The .env file is loaded automatically in
    // non-production environments; in production, set env vars on the host.
    ConfigModule.forRoot({
      isGlobal: true,
      envFilePath: '.env',
    }),

    // TypeORM — PostgreSQL connection configured from DATABASE_URL env var.
    // Set synchronize: false in production and use migrations instead.
    TypeOrmModule.forRootAsync({
      imports: [ConfigModule],
      inject: [ConfigService],
      useFactory: (config: ConfigService) => ({
        type: 'postgres',
        url: config.get<string>('DATABASE_URL'),
        autoLoadEntities: true,
        // TODO: set to false and use migrations once the schema stabilises
        synchronize: config.get<string>('NODE_ENV') !== 'production',
        ssl:
          config.get<string>('NODE_ENV') === 'production'
            ? { rejectUnauthorized: false }
            : false,
        logging: config.get<string>('NODE_ENV') === 'development',
      }),
    }),

    // TODO: Add BullMQ module for job queues (payouts, SMS, automation rules)
    // BullModule.forRootAsync({ ... useFactory: (config) => ({ connection: { url: config.get('REDIS_URL') } }) })

    // TODO: Add feature modules as they are built, e.g.:
    // FleetModule, BookingModule, FinanceModule, InvestorModule,
    // AutomationModule, CrmModule, SmsModule, MpesaModule
  ],
  controllers: [AppController],
  providers: [AppService],
})
export class AppModule {}
