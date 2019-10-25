package uk.gov.hmrc.XT_XWF2RT.config

import javax.inject.{Inject, Singleton}

import play.api.i18n.MessagesApi
import play.api.mvc.Request
import play.twirl.api.Html
import uk.gov.hmrc.play.bootstrap.http.FrontendErrorHandler
import uk.gov.hmrc.XT_XWF2RT.views.html.error_template

@Singleton
class ErrorHandler @Inject()(val messagesApi: MessagesApi, implicit val appConfig: AppConfig) extends FrontendErrorHandler {
  override def standardErrorTemplate(pageTitle: String, heading: String, message: String)(implicit request: Request[_]): Html =
    error_template(pageTitle, heading, message)
}
